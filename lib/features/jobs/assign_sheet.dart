/// Putting a stage in somebody's hands.
///
/// D-008 is the whole point of this sheet. `caster_dashboard` scoped a vendor's queue with a
/// decorative "Assigned to Me" chip that had nothing behind it, and all 46 mockups rendered the
/// same hardcoded identity — including on the external vendor's screen. The row this sheet writes
/// (`job_stages.assigned_partner`) *is* what a partner principal's RLS policy reads, so an
/// assignment made here is the only thing that puts a job on a vendor's queue, and a mis-assignment
/// is what would show one vendor another vendor's work.
///
/// D-002 narrows the choice rather than trusting the operator: only casting and certification
/// leave the building, and `CustomerRepository.partnersForStage` returns an empty list for the
/// other twelve. A caster cannot be offered for polishing, and `JobRepository.assignStage` refuses
/// the combination server-side even if one were.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/customer_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

part 'assign_sheet.g.dart';

/// The columns an assignment picker needs. `user_roles` is deliberately not joined: any internal
/// operator can be given a bench stage, and pulling the role rows here would make the picker wait
/// on a join it never reads.
const _directorySelect =
    'id, org_id, principal, full_name, title, initials, email, phone, avatar_path, '
    'is_active, created_at';

/// Everyone in the org who can hold a stage.
///
/// RLS (`users_read`) already restricts this to internal principals inside the caller's own org;
/// the explicit `principal` filter is belt and braces, and the `is_active` filter is the practical
/// one — a picker that offers a bench operator who left in March is how a job goes quiet.
@Riverpod(keepAlive: true)
Future<List<AppUser>> orgUsers(Ref ref) async {
  final me = await ref.watch(currentUserProvider.future);
  if (me == null || !me.isInternal) return const <AppUser>[];

  final client = ref.watch(supabaseProvider);
  final rows = await guard(
    () => client
        .from('app_users')
        .select(_directorySelect)
        // Convention 6: the enum crosses the wire as its Postgres value.
        .eq('principal', PrincipalClass.internal.wire)
        .eq('is_active', true)
        .order('full_name', ascending: true),
  );
  return [for (final row in rows) AppUser.fromJson(row)];
}

/// The same people, keyed by id — what a rail turns `assigned_to` uuids into.
@Riverpod(keepAlive: true)
Future<Map<String, AppUser>> orgUsersById(Ref ref) async {
  final users = await ref.watch(orgUsersProvider.future);
  return {for (final user in users) user.id: user};
}

/// Every partner on file, keyed by id, for the same reason.
@Riverpod(keepAlive: true)
Future<Map<String, Partner>> partnersById(Ref ref) async {
  final partners = await ref.watch(partnerDirectoryProvider(null).future);
  return {for (final partner in partners) partner.id: partner};
}

// ================================================================= sheet

/// Who the stage goes to, and when it is expected back.
final class AssignSheet extends ConsumerStatefulWidget {
  const AssignSheet({super.key, required this.jobId, required this.stage, this.current});

  final String jobId;
  final LifecycleStage stage;

  /// The rail row as it stands, so the sheet opens on the current answer rather than on a blank.
  final JobStage? current;

  /// Open the sheet. Returns true when an assignment was written.
  static Future<bool> show(
    BuildContext context, {
    required String jobId,
    required LifecycleStage stage,
    JobStage? current,
  }) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AssignSheet(jobId: jobId, stage: stage, current: current),
    );
    return saved ?? false;
  }

  @override
  ConsumerState<AssignSheet> createState() => _AssignSheetState();
}

enum _Holder { inHouse, partner }

class _AssignSheetState extends ConsumerState<AssignSheet> {
  late _Holder _mode;
  String? _userId;
  String? _partnerId;
  DateTime? _expectedAt;
  final TextEditingController _search = TextEditingController();
  bool _saving = false;

  bool get _partnerAllowed => widget.stage.isPartnerStage;

  @override
  void initState() {
    super.initState();
    final current = widget.current;
    _userId = current?.assignedTo;
    _partnerId = current?.assignedPartner;
    _expectedAt = current?.expectedAt?.toLocal();
    _mode = _partnerId != null && _partnerAllowed ? _Holder.partner : _Holder.inHouse;
    _search.addListener(_onSearchChanged);
  }

  void _onSearchChanged() => setState(() {});

  @override
  void dispose() {
    _search
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  bool get _hasChoice =>
      _mode == _Holder.inHouse ? _userId != null : _partnerId != null;

  /// True when the sheet would write exactly what is already on the row.
  bool get _unchanged {
    final current = widget.current;
    final sameUser = (_mode == _Holder.inHouse ? _userId : null) == current?.assignedTo;
    final samePartner = (_mode == _Holder.partner ? _partnerId : null) == current?.assignedPartner;
    final sameDate = _expectedAt?.toUtc() == current?.expectedAt?.toUtc();
    return sameUser && samePartner && sameDate;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;

    return Padding(
      padding: EdgeInsets.only(
        left: Spacing.md,
        right: Spacing.md,
        bottom: MediaQuery.viewInsetsOf(context).bottom + Spacing.lg,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Assign ${widget.stage.label}', style: context.text.headlineSmall),
            const SizedBox(height: Spacing.xs),
            Text(
              _partnerAllowed
                  ? '${widget.stage.label} can be done in-house or sent out. A partner only sees '
                      'this job once the stage is assigned to them.'
                  : '${widget.stage.label} is in-house work. Only casting and certification leave '
                      'the building.',
              style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.md),
            if (_partnerAllowed)
              DhSegmented<_Holder>(
                value: _mode,
                onChanged: (mode) => setState(() => _mode = mode),
                segments: const [
                  DhSegment(
                    value: _Holder.inHouse,
                    label: 'In-house',
                    icon: Icons.groups_outlined,
                  ),
                  DhSegment(
                    value: _Holder.partner,
                    label: 'Partner',
                    icon: Icons.local_shipping_outlined,
                  ),
                ],
              ),
            if (_partnerAllowed) const SizedBox(height: Spacing.md),
            Flexible(
              child: _mode == _Holder.inHouse ? _buildPeople(context) : _buildPartners(context),
            ),
            const SizedBox(height: Spacing.md),
            _ExpectedByField(
              value: _expectedAt,
              onChanged: (value) => setState(() => _expectedAt = value),
            ),
            const SizedBox(height: Spacing.md),
            FilledButton.icon(
              onPressed: _saving || !_hasChoice || _unchanged ? null : () => unawaited(_save()),
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded, size: 18),
              label: Text(
                _mode == _Holder.inHouse ? 'Assign in-house' : 'Send to this partner',
              ),
            ),
            if (widget.current?.isUnassigned == false) ...[
              const SizedBox(height: Spacing.sm),
              TextButton.icon(
                onPressed: _saving ? null : () => unawaited(_clear()),
                icon: const Icon(Icons.person_off_outlined, size: 18),
                label: const Text('Clear the assignment'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- in-house

  Widget _buildPeople(BuildContext context) {
    final directory = ref.watch(orgUsersProvider);

    return switch (directory) {
      AsyncLoading() => const LoadingSkeleton.list(count: 3),
      AsyncError(error: final error) => ErrorState(
          compact: true,
          title: 'The team list did not load',
          message: error is DhFailure ? error.message : 'Try again in a moment.',
          detail: error is DhFailure ? error.detail : null,
          onRetry: () => ref.invalidate(orgUsersProvider),
        ),
      AsyncValue(value: final users?) => _peopleList(context, users),
    };
  }

  Widget _peopleList(BuildContext context, List<AppUser> users) {
    final term = _search.text.trim().toLowerCase();
    final matches = term.isEmpty
        ? users
        : [
            for (final user in users)
              if (user.fullName.toLowerCase().contains(term) ||
                  (user.title ?? '').toLowerCase().contains(term) ||
                  (user.initials ?? '').toLowerCase().contains(term))
                user,
          ];

    if (users.isEmpty) {
      return const EmptyState(
        compact: true,
        icon: Icons.groups_outlined,
        title: 'Nobody to assign to',
        message: 'No active internal accounts in this workshop. An admin adds people under '
            'Settings before work can be handed out.',
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          decoration: const InputDecoration(
            hintText: 'Find a person',
            isDense: true,
            prefixIcon: Icon(Icons.search_rounded, size: 20),
          ),
        ),
        const SizedBox(height: Spacing.sm + Spacing.xs),
        Flexible(
          child: matches.isEmpty
              ? EmptyState(
                  compact: true,
                  icon: Icons.person_search_outlined,
                  title: 'No match for "${_search.text.trim()}"',
                  message: 'Search by name, initials or job title.',
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: matches.length,
                  separatorBuilder: (_, __) => const SizedBox(height: Spacing.sm),
                  itemBuilder: (context, index) {
                    final user = matches[index];
                    return SelectableTile(
                      inGroup: true,
                      dense: true,
                      title: user.fullName,
                      blurb: user.subtitle,
                      leading: PersonAvatar(
                        name: user.fullName,
                        tone: _userId == user.id ? AvatarTone.accent : AvatarTone.neutral,
                      ),
                      selected: _userId == user.id,
                      onTap: () => setState(() => _userId = user.id),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- partner

  Widget _buildPartners(BuildContext context) {
    final partners = ref.watch(partnersForStageProvider(widget.stage));

    return switch (partners) {
      AsyncLoading() => const LoadingSkeleton.list(count: 2),
      AsyncError(error: final error) => ErrorState(
          compact: true,
          title: 'The partner list did not load',
          message: error is DhFailure ? error.message : 'Try again in a moment.',
          detail: error is DhFailure ? error.detail : null,
          onRetry: () => ref.invalidate(partnersForStageProvider(widget.stage)),
        ),
      AsyncValue(value: final list?) when list.isEmpty => EmptyState(
          compact: true,
          icon: Icons.handshake_outlined,
          title: 'No partner can take ${widget.stage.label}',
          message: widget.stage.isPartnerStage
              ? 'Add an active ${widget.stage == LifecycleStage.casting ? 'casting' : 'gem lab'} '
                  'partner under Partners, then assign the stage.'
              : 'Only casting and certification can be sent out.',
        ),
      AsyncValue(value: final list?) => ListView.separated(
          shrinkWrap: true,
          itemCount: list.length,
          separatorBuilder: (_, __) => const SizedBox(height: Spacing.sm),
          itemBuilder: (context, index) {
            final partner = list[index];
            return SelectableTile(
              inGroup: true,
              dense: true,
              title: partner.name,
              blurb: [
                partner.kind.label,
                if (partner.contactName != null) partner.contactName!,
                if (!partner.isGstRegistered) 'No GSTIN on file',
              ].join(' · '),
              leading: PersonAvatar(
                name: partner.name,
                tone: _partnerId == partner.id ? AvatarTone.accent : AvatarTone.neutral,
              ),
              selected: _partnerId == partner.id,
              onTap: () => setState(() => _partnerId = partner.id),
            );
          },
        ),
    };
  }

  // ---------------------------------------------------------------- write

  Future<void> _save() async {
    setState(() => _saving = true);
    final repository = ref.read(jobRepositoryProvider);
    final expected = _expectedAt;

    try {
      await repository.assignStage(
        jobId: widget.jobId,
        stage: widget.stage,
        // The two holders are mutually exclusive on a rail row: assigning one clears the other,
        // or a job would sit on a vendor's queue and a bench operator's list at once.
        assignedTo: _mode == _Holder.inHouse ? Opt(_userId!) : const Opt<String>.clear(),
        assignedPartner:
            _mode == _Holder.partner ? Opt(_partnerId!) : const Opt<String>.clear(),
        expectedAt: expected == null ? const Opt<DateTime>.clear() : Opt(expected),
      );
      if (!mounted) return;
      // Message first, pop second: the snackbar is hosted by the root messenger, but resolving it
      // through a context whose element has just been unmounted is a race not worth running.
      showDone(context, '${widget.stage.label} assigned.');
      Navigator.of(context).pop(true);
    } on DhFailure catch (failure) {
      if (!mounted) return;
      setState(() => _saving = false);
      showFailure(context, failure);
    }
  }

  Future<void> _clear() async {
    final confirmed = await confirmAction(
      context,
      title: 'Clear the assignment?',
      message: 'Nobody will hold ${widget.stage.label}. If it is with a partner, the job leaves '
          'their queue immediately.',
      confirmLabel: 'Clear it',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    try {
      await ref.read(jobRepositoryProvider).assignStage(
            jobId: widget.jobId,
            stage: widget.stage,
            assignedTo: const Opt<String>.clear(),
            assignedPartner: const Opt<String>.clear(),
            expectedAt: const Opt<DateTime>.clear(),
          );
      if (!mounted) return;
      showDone(context, '${widget.stage.label} is unassigned.');
      Navigator.of(context).pop(true);
    } on DhFailure catch (failure) {
      if (!mounted) return;
      setState(() => _saving = false);
      showFailure(context, failure);
    }
  }
}

// ================================================================= expected-by

/// "Expected Aug 12 05:00 PM" — the promise the rail row carries, and what makes `JobStage.isLate`
/// mean something. The mockup printed the sentence and had no field behind it.
final class _ExpectedByField extends StatelessWidget {
  const _ExpectedByField({required this.value, required this.onChanged});

  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final current = value;

    return DhCard(
      tone: DhCardTone.inset,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm + Spacing.xs,
      ),
      onTap: () => unawaited(_pick(context)),
      child: Row(
        children: [
          Icon(Icons.event_outlined, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Spacing.sm + Spacing.xs),
          Expanded(
            child: DataPair.mono(
              label: 'Expected back',
              value: current == null
                  ? 'Not promised'
                  : DateFormat('d MMM yyyy · HH:mm').format(current),
            ),
          ),
          if (current != null)
            IconButton(
              onPressed: () => onChanged(null),
              tooltip: 'Clear the expected date',
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final seed = value ?? DateTime(now.year, now.month, now.day + 3, 17);

    final date = await showDatePicker(
      context: context,
      initialDate: seed,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      helpText: 'Expected back on',
    );
    if (date == null || !context.mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(seed),
      helpText: 'Expected back by',
    );
    if (!context.mounted) return;

    final at = time ?? TimeOfDay.fromDateTime(seed);
    onChanged(DateTime(date.year, date.month, date.day, at.hour, at.minute));
  }
}
