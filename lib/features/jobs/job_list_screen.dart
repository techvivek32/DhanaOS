/// The job list — the screen the sidebar carried `aria-current` for on every one of the 46
/// mockups and which was never actually drawn.
///
/// The top bar's placeholder has read "Job ID, Customer, or Specialist" since the first export and
/// had nothing behind it. This is what it lands on: `v_job_list` filtered by code, title and
/// customer, narrowed by stage, status, priority and lateness, and sorted four ways. The filter is
/// a value type (`JobListFilter`), so two surfaces asking the same question share one subscription
/// instead of opening two sockets.
///
/// Three states the corpus never drew are drawn here, because on a real shop floor they are most
/// of the day: a list that is loading, a list that failed, and a list that is empty. The empty
/// state distinguishes "no work" from "no matches" — telling an operator to create a job when the
/// truth is that their filter excludes everything is worse than saying nothing.
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
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/job.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

part 'job_list_screen.g.dart';

// ================================================================= filter state

/// The live filter behind the list.
///
/// Kept alive on purpose: an operator who opens a job, works it and comes back expects the same
/// five filters they left set. `JobListFilter.copyWith` cannot express "clear the search term"
/// (a null argument there means "leave it alone"), so every mutation rebuilds the whole value
/// through the main constructor instead.
@Riverpod(keepAlive: true)
class JobListFilterController extends _$JobListFilterController {
  @override
  JobListFilter build() => const JobListFilter();

  JobListFilter _rebuild({
    Set<JobStatus>? statuses,
    Set<LifecycleStage>? stages,
    Set<Priority>? priorities,
    String? search,
    bool clearSearch = false,
    bool? openOnly,
    bool? dueSoonOnly,
    bool? overdueOnly,
    bool? blockedOnly,
    DraftScope? draftScope,
    JobListSort? sort,
  }) =>
      JobListFilter(
        statuses: statuses ?? state.statuses,
        stages: stages ?? state.effectiveStages,
        priorities: priorities ?? state.priorities,
        customerId: state.customerId,
        assignedTo: state.assignedTo,
        assignedPartner: state.assignedPartner,
        search: clearSearch ? null : (search ?? state.search),
        openOnly: openOnly ?? state.openOnly,
        dueSoonOnly: dueSoonOnly ?? state.dueSoonOnly,
        overdueOnly: overdueOnly ?? state.overdueOnly,
        blockedOnly: blockedOnly ?? state.blockedOnly,
        draftScope: draftScope ?? state.draftScope,
        sort: sort ?? state.sort,
        limit: state.limit,
      );

  void setSearch(String? term) {
    final trimmed = term?.trim();
    state = trimmed == null || trimmed.isEmpty
        ? _rebuild(clearSearch: true)
        : _rebuild(search: trimmed);
  }

  void toggleStage(LifecycleStage stage) {
    final next = {...state.effectiveStages};
    if (!next.remove(stage)) next.add(stage);
    state = _rebuild(stages: next);
  }

  void setStages(Set<LifecycleStage> stages) => state = _rebuild(stages: stages);

  void setStatuses(Set<JobStatus> statuses) => state = _rebuild(statuses: statuses);

  void toggleStatus(JobStatus status) {
    final next = {...state.statuses};
    if (!next.remove(status)) next.add(status);
    // Asking for a closed status only makes sense with the open-only filter off. The repository
    // intersects the two rather than letting one win, so leaving `openOnly` on here would return
    // an empty list the operator cannot explain.
    final wantsClosed = next.any((s) => !s.isOpen);
    state = _rebuild(statuses: next, openOnly: wantsClosed ? false : state.openOnly);
  }

  void togglePriority(Priority priority) {
    final next = {...state.priorities};
    if (!next.remove(priority)) next.add(priority);
    state = _rebuild(priorities: next);
  }

  void setSort(JobListSort sort) => state = _rebuild(sort: sort);

  void setOpenOnly({required bool value}) => state = _rebuild(openOnly: value);

  void setOverdueOnly({required bool value}) => state = _rebuild(overdueOnly: value);

  void setDueSoonOnly({required bool value}) => state = _rebuild(dueSoonOnly: value);

  void setBlockedOnly({required bool value}) => state = _rebuild(blockedOnly: value);

  void setDraftScope(DraftScope scope) => state = _rebuild(draftScope: scope);

  /// Back to "every open job, soonest first" — but the search term is kept, because clearing a
  /// filter chip should not also wipe what the operator typed.
  void clearFilters() => state = JobListFilter(search: state.search);
}

/// How many narrowing choices are on, for the "Clear" affordance and for the empty state's copy.
int activeFilterCount(JobListFilter filter) =>
    filter.effectiveStages.length +
    filter.statuses.length +
    filter.priorities.length +
    (filter.overdueOnly ? 1 : 0) +
    (filter.dueSoonOnly ? 1 : 0) +
    (filter.blockedOnly ? 1 : 0) +
    (filter.draftScope == DraftScope.all ? 0 : 1) +
    (filter.openOnly ? 0 : 1);

// ================================================================= screen

final class JobListScreen extends ConsumerStatefulWidget {
  const JobListScreen({super.key, this.query});

  /// `?q=` from the top bar's search field — the one query the whole app agrees on.
  final String? query;

  @override
  ConsumerState<JobListScreen> createState() => _JobListScreenState();
}

class _JobListScreenState extends ConsumerState<JobListScreen> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final incoming = widget.query?.trim();
    if (incoming != null && incoming.isNotEmpty) {
      _search.text = incoming;
      // The controller is keepAlive, so this has to run after the first frame or it would notify
      // listeners during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(jobListFilterControllerProvider.notifier).setSearch(incoming);
      });
    }
  }

  /// The top bar can re-issue `?q=` while this screen is already standing. Applying it from a
  /// post-frame callback rather than inline: `didUpdateWidget` runs inside the build phase, and
  /// writing to a provider there is what Riverpod refuses outright.
  @override
  void didUpdateWidget(JobListScreen old) {
    super.didUpdateWidget(old);
    final incoming = widget.query?.trim() ?? '';
    if (old.query != widget.query && incoming != _search.text.trim()) {
      _search.text = incoming;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(jobListFilterControllerProvider.notifier).setSearch(incoming);
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// A keystroke is not a query. 300ms is long enough that typing "DH-2026" is one round trip and
  /// short enough that it still feels like search-as-you-type.
  void _onSearchChanged(String value) {
    // Repaint now so the clear affordance appears with the first character; query later.
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) ref.read(jobListFilterControllerProvider.notifier).setSearch(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(jobListFilterControllerProvider);
    final jobs = ref.watch(jobListLiveProvider(filter));
    final permissions = ref.watch(permissionsProvider);

    return Scaffold(
      backgroundColor: context.scheme.surface,
      floatingActionButton: permissions.canEditJob
          ? FloatingActionButton.extended(
              onPressed: () => context.push(Paths.newJob),
              icon: const Icon(Icons.add_rounded),
              label: const Text('New job order'),
            )
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.md,
              Spacing.md,
              Spacing.sm,
            ),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: _onSearchChanged,
              onSubmitted: (value) {
                _debounce?.cancel();
                ref.read(jobListFilterControllerProvider.notifier).setSearch(value);
              },
              decoration: InputDecoration(
                hintText: 'Job code, customer or title',
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear the search',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          _debounce?.cancel();
                          _search.clear();
                          ref.read(jobListFilterControllerProvider.notifier).setSearch(null);
                          setState(() {});
                        },
                      ),
              ),
            ),
          ),
          _FilterBar(filter: filter),
          _ResultHeader(filter: filter, jobs: jobs),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(jobListLiveProvider(filter)),
              child: switch (jobs) {
                AsyncValue(value: final live?) => _list(context, filter, live.data),
                AsyncError(error: final error) => ListView(
                    children: [
                      SizedBox(height: MediaQuery.sizeOf(context).height * 0.12),
                      ErrorState(
                        title: 'The job list did not load',
                        message: error is DhFailure
                            ? error.message
                            : 'Check the connection and pull down to try again.',
                        detail: error is DhFailure ? error.detail : null,
                        onRetry: () => ref.invalidate(jobListLiveProvider(filter)),
                      ),
                    ],
                  ),
                _ => const Padding(
                    padding: EdgeInsets.all(Spacing.md),
                    child: LoadingSkeleton.list(count: 5),
                  ),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, JobListFilter filter, List<JobListItem> items) {
    if (items.isEmpty) {
      final narrowed = activeFilterCount(filter) > 0 || (filter.search?.isNotEmpty ?? false);
      return ListView(
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * 0.10),
          if (narrowed)
            EmptyState(
              icon: Icons.filter_alt_off_outlined,
              title: 'No job matches',
              message: filter.search == null
                  ? 'Nothing in this workshop is at those stages right now. Widen the filter to '
                      'see more.'
                  : 'Nothing matches "${filter.search}" with the filters you have on. Search by '
                      'job code, customer or title.',
              actionLabel: 'Clear the filters',
              onAction: () => ref.read(jobListFilterControllerProvider.notifier).clearFilters(),
            )
          else
            EmptyState(
              icon: Icons.inbox_outlined,
              title: 'No open jobs',
              message: 'Nothing is in production. Start a job order and it appears here the '
                  'moment it is committed.',
              actionLabel: 'New job order',
              onAction: () => context.push(Paths.newJob),
            ),
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.sm, Spacing.md, Spacing.xxl + 40),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: Spacing.sm + Spacing.xs),
      itemBuilder: (context, index) => JobRowCard(item: items[index]),
    );
  }
}

// ================================================================= header

final class _ResultHeader extends ConsumerWidget {
  const _ResultHeader({required this.filter, required this.jobs});

  final JobListFilter filter;
  final AsyncValue<Live<List<JobListItem>>> jobs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = jobs.value;
    final count = live?.data.length;
    // The repository pages with `range`, so a full page means "at least this many", not "exactly".
    final capped = count != null && count >= filter.limit;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.xs, Spacing.md, Spacing.sm),
      child: Row(
        children: [
          Text(
            count == null ? 'Loading' : '$count${capped ? '+' : ''} ${count == 1 ? 'job' : 'jobs'}',
            style: AppTheme.mono(
              size: 11.5,
              weight: FontWeight.w600,
              color: context.scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Spacing.sm),
          if (live != null) LivePulse(status: live.status, dense: true),
          const Spacer(),
          PopupMenuButton<JobListSort>(
            tooltip: 'Change the order',
            position: PopupMenuPosition.under,
            initialValue: filter.sort,
            onSelected: (sort) =>
                ref.read(jobListFilterControllerProvider.notifier).setSort(sort),
            itemBuilder: (_) => [
              for (final sort in JobListSort.values)
                PopupMenuItem(value: sort, child: Text(sort.label)),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.swap_vert_rounded, size: 17, color: context.scheme.onSurfaceVariant),
                const SizedBox(width: Spacing.xs),
                Text(
                  filter.sort.label,
                  style: context.text.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================= filter bar

final class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.filter});

  final JobListFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(jobListFilterControllerProvider.notifier);
    final stages = filter.effectiveStages;
    final active = activeFilterCount(filter);

    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        children: [
          if (active > 0) ...[
            ActionChip(
              avatar: const Icon(Icons.close_rounded, size: 16),
              label: Text('Clear $active'),
              onPressed: notifier.clearFilters,
            ),
            const SizedBox(width: Spacing.sm),
          ],
          _PickerChip(
            label: stages.isEmpty
                ? 'Stage'
                : stages.length == 1
                    ? stages.first.label
                    : '${stages.length} stages',
            selected: stages.isNotEmpty,
            onTap: () => unawaited(_pickStages(context, ref)),
          ),
          const SizedBox(width: Spacing.sm),
          _PickerChip(
            label: filter.statuses.isEmpty
                ? 'Status'
                : filter.statuses.length == 1
                    ? filter.statuses.first.label
                    : '${filter.statuses.length} statuses',
            selected: filter.statuses.isNotEmpty,
            onTap: () => unawaited(_pickStatuses(context, ref)),
          ),
          const SizedBox(width: Spacing.sm),
          for (final priority in Priority.values) ...[
            FilterChip(
              label: Text(priority.label),
              selected: filter.priorities.contains(priority),
              onSelected: (_) => notifier.togglePriority(priority),
            ),
            const SizedBox(width: Spacing.sm),
          ],
          FilterChip(
            avatar: const Icon(Icons.event_busy_outlined, size: 16),
            label: const Text('Overdue'),
            selected: filter.overdueOnly,
            onSelected: (value) => notifier.setOverdueOnly(value: value),
          ),
          const SizedBox(width: Spacing.sm),
          FilterChip(
            avatar: const Icon(Icons.report_outlined, size: 16),
            label: const Text('Blocked'),
            selected: filter.blockedOnly,
            onSelected: (value) => notifier.setBlockedOnly(value: value),
          ),
          const SizedBox(width: Spacing.sm),
          FilterChip(
            avatar: const Icon(Icons.edit_note_rounded, size: 16),
            label: const Text('Drafts'),
            selected: filter.draftScope == DraftScope.draftsOnly,
            onSelected: (value) => notifier
                .setDraftScope(value ? DraftScope.draftsOnly : DraftScope.all),
          ),
          const SizedBox(width: Spacing.sm),
          FilterChip(
            avatar: const Icon(Icons.inventory_outlined, size: 16),
            label: const Text('Include closed'),
            selected: !filter.openOnly,
            onSelected: (value) => notifier.setOpenOnly(value: !value),
          ),
          const SizedBox(width: Spacing.md),
        ],
      ),
    );
  }

  /// D-002: all fourteen, in rail order. The dashboard's eight counters are a view over these,
  /// never a rival list, so the picker offers the whole vocabulary.
  Future<void> _pickStages(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _MultiPickSheet<LifecycleStage>(
        title: 'Filter by stage',
        subtitle: 'The 14-stage rail, in order. Pick as many as you want to watch.',
        values: LifecycleStage.values,
        selected: ref.read(jobListFilterControllerProvider).effectiveStages,
        labelOf: (stage) => stage.label,
        trailingOf: (stage) => '${stage.seq}',
        onToggle: (stage) =>
            ref.read(jobListFilterControllerProvider.notifier).toggleStage(stage),
        onClear: () => ref.read(jobListFilterControllerProvider.notifier).setStages({}),
      ),
    );
  }

  /// D-006: the five states no mockup drew are in this list, because they are the ones an
  /// operator most often needs to find.
  Future<void> _pickStatuses(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _MultiPickSheet<JobStatus>(
        title: 'Filter by status',
        subtitle: 'Status is orthogonal to stage — a job can be on hold while sitting at casting.',
        values: JobStatus.values,
        selected: ref.read(jobListFilterControllerProvider).statuses,
        labelOf: (status) => status.label,
        trailingOf: (status) => status.isOpen ? 'open' : 'closed',
        onToggle: (status) =>
            ref.read(jobListFilterControllerProvider.notifier).toggleStatus(status),
        onClear: () => ref.read(jobListFilterControllerProvider.notifier).setStatuses({}),
      ),
    );
  }
}

final class _PickerChip extends StatelessWidget {
  const _PickerChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FilterChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        avatar: const Icon(Icons.expand_more_rounded, size: 16),
        onSelected: (_) => onTap(),
      );
}

/// A tick-list sheet that writes straight through to the filter, so the list behind it updates as
/// each row is tapped rather than on a Done button.
final class _MultiPickSheet<T> extends StatefulWidget {
  const _MultiPickSheet({
    super.key,
    required this.title,
    required this.subtitle,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onToggle,
    required this.onClear,
    this.trailingOf,
  });

  final String title;
  final String subtitle;
  final List<T> values;
  final Set<T> selected;
  final String Function(T) labelOf;
  final String Function(T)? trailingOf;
  final void Function(T) onToggle;
  final VoidCallback onClear;

  @override
  State<_MultiPickSheet<T>> createState() => _MultiPickSheetState<T>();
}

class _MultiPickSheetState<T> extends State<_MultiPickSheet<T>> {
  late Set<T> _selected = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(widget.title, style: context.text.headlineSmall)),
                    if (_selected.isNotEmpty)
                      TextButton(
                        onPressed: () {
                          widget.onClear();
                          setState(() => _selected = <T>{});
                        },
                        child: const Text('Clear'),
                      ),
                  ],
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  widget.subtitle,
                  style: context.text.bodySmall?.copyWith(
                    color: context.scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.values.length,
              itemBuilder: (context, index) {
                final value = widget.values[index];
                final on = _selected.contains(value);
                return CheckboxListTile(
                  value: on,
                  dense: true,
                  title: Text(widget.labelOf(value)),
                  secondary: widget.trailingOf == null
                      ? null
                      : Text(
                          widget.trailingOf!(value),
                          style: AppTheme.mono(
                            size: 11,
                            color: context.scheme.onSurfaceVariant,
                          ),
                        ),
                  onChanged: (_) {
                    widget.onToggle(value);
                    setState(() {
                      if (on) {
                        _selected.remove(value);
                      } else {
                        _selected.add(value);
                      }
                    });
                  },
                );
              },
            ),
          ),
          const SizedBox(height: Spacing.md),
        ],
      ),
    );
  }
}

// ================================================================= row

/// One job, dense enough to scan a column of them and complete enough to act on.
///
/// Everything that is data — the code, the dwell, the total — is monospaced, because the reason
/// the source system mandated a mono face was so an operator could compare digits down a column.
final class JobRowCard extends StatelessWidget {
  const JobRowCard({super.key, required this.item, this.onTap});

  final JobListItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final total = item.quoteTotal;

    return DhCard(
      onTap: onTap ?? () => context.push(Paths.job(item.id)),
      accent: item.isBlocked ? scheme.error : null,
      semanticLabel: '${item.displayCode}, ${item.displayTitle}, '
          '${item.currentStage?.label ?? 'not started'}, ${item.status.label}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusChip.code(item.displayCode, dense: true),
              const SizedBox(width: Spacing.sm),
              PriorityChip(item.priority, dense: true, showStandard: false),
              const Spacer(),
              StatusChip.job(item.status, dense: true),
            ],
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          Text(
            item.displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.titleMedium,
          ),
          if (item.customerName != null) ...[
            const SizedBox(height: 2),
            Text(
              item.customerName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: Spacing.sm + Spacing.xs),
          // D-002: the rail answers "roughly how far along"; the detail screen answers the rest.
          JobStageRail.compact(
            nodes: StageNode.railFor(
              active: item.currentStage ?? LifecycleStage.inquiry,
              blocked: item.isBlocked,
            ),
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          Row(
            children: [
              if (item.holderName != null) ...[
                Icon(
                  item.isWithPartner
                      ? Icons.local_shipping_outlined
                      : Icons.person_outline_rounded,
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Spacing.xs),
                Flexible(
                  child: Text(
                    item.holderName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: Spacing.sm + Spacing.xs),
              ],
              if (item.stageEnteredAt != null)
                Text(
                  item.dwellLabel,
                  style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
                ),
              const Spacer(),
              if (total != null)
                Text(
                  total.format(compact: true),
                  style: AppTheme.mono(
                    size: 12.5,
                    weight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
            ],
          ),
          if (item.isBlocked || item.overdue || item.dueSoon || item.requestedDelivery != null) ...[
            const SizedBox(height: Spacing.sm),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.xs,
              children: [
                if (item.isBlocked)
                  StatusChip(
                    label: item.openExceptions == 1
                        ? '1 open issue'
                        : '${item.openExceptions} open issues',
                    tone: ChipTone.danger,
                    icon: Icons.error_outline_rounded,
                    dense: true,
                  ),
                if (item.overdue)
                  const StatusChip(
                    label: 'Overdue',
                    tone: ChipTone.danger,
                    icon: Icons.event_busy_outlined,
                    dense: true,
                  )
                else if (item.dueSoon)
                  const StatusChip(
                    label: 'Due now',
                    tone: ChipTone.warning,
                    icon: Icons.schedule_rounded,
                    dense: true,
                  )
                else if (item.requestedDelivery != null)
                  StatusChip.code(
                    'Due ${DateFormat('d MMM').format(item.requestedDelivery!.toLocal())}',
                    dense: true,
                  ),
                if (item.isDraft)
                  const StatusChip(
                    label: 'Draft',
                    tone: ChipTone.neutral,
                    icon: Icons.edit_note_rounded,
                    dense: true,
                    tooltip: 'Not committed. The 14-stage rail is seeded at commit, so this job '
                        'has no rail yet.',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
