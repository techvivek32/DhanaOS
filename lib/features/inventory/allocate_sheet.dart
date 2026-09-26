/// The job picker behind the "Assign" button.
///
/// `inventory_management` had exactly one button per stock row, labelled Assign, and it was a
/// `<button>` with no handler and no picker anywhere in the export. Assign *what* to *which job*
/// was never answered — and there are two different answers, which is why this sheet separates
/// them:
///
///   * **Reserve** holds the stock for a job. The stone stays on the shelf and the balance does
///     not move; `qty_allocated` rises so no other job can be promised the same gram.
///   * **Issue** is the movement that takes it out of the vault. It is append-only and cannot be
///     edited afterwards, so it is confirmed before it is posted.
///
/// A reservation can also satisfy one specific stone line on the job, which is what makes the job
/// screen stop reporting that stone as unfound ([Stone.awaitingAllocation]). Lines are only
/// offered when they do not contradict the item: satisfying a lab-grown line out of a natural
/// parcel is a disclosure failure, not a substitution (D-012).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/inventory/inventory_actions.dart';
import 'package:dhanaos/features/inventory/inventory_gateway.dart';
import 'package:dhanaos/features/inventory/inventory_widgets.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// Reserve stock for a job. Returns the allocation when one was made.
Future<StockAllocation?> showAllocateSheet(
  BuildContext context, {
  required InventoryItem item,
  String? jobId,
}) =>
    showModalBottomSheet<StockAllocation>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        // The sheet holds a stepper and a text field, so it has to sit above the keyboard.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
        child: _AllocateSheet(item: item, initialJobId: jobId),
      ),
    );

/// Pick a committed job. Used by the allocate sheet, by an issue-straight-to-a-job movement and
/// by goods-in, which is always about a job.
///
/// Drafts are excluded on purpose: a draft has no rail and no bench waiting on it, so holding
/// stock against one holds it against work that may never be committed.
Future<JobListItem?> pickJobSheet(
  BuildContext context, {
  required String title,
  required String blurb,
}) =>
    showModalBottomSheet<JobListItem>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
        child: _JobPickerSheet(title: title, blurb: blurb),
      ),
    );

// ================================================================= allocate

final class _AllocateSheet extends ConsumerStatefulWidget {
  const _AllocateSheet({required this.item, this.initialJobId});

  final InventoryItem item;
  final String? initialJobId;

  @override
  ConsumerState<_AllocateSheet> createState() => _AllocateSheetState();
}

class _AllocateSheetState extends ConsumerState<_AllocateSheet> {
  JobListItem? _job;
  Stone? _stone;
  late double _qty = widget.item.isSerialized
      ? 1
      // A sensible first offer, never more than is free: the keeper adjusts down far more often
      // than up.
      : (widget.item.qtyAvailable < 1 ? widget.item.qtyAvailable : 1);
  bool _issueNow = false;

  InventoryItem get _item => widget.item;

  double get _available => _item.qtyAvailable;

  @override
  void initState() {
    super.initState();
    final jobId = widget.initialJobId;
    if (jobId != null) {
      // The list the picker uses is the cheapest way to resolve a passed-in id into something
      // with a code on it; until it lands the job line reads as loading rather than as chosen.
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_resolveJob(jobId)));
    }
  }

  Future<void> _resolveJob(String jobId) async {
    final jobs = await ref.read(allocatableJobsProvider(null).future);
    if (!mounted) return;
    setState(() => _job = jobFrom(jobs, jobId));
  }

  /// Convention 8: name what is missing, do not just grey the button.
  String? get _blockReason {
    if (_available <= 0) {
      return 'None of ${_item.code} is free. ${_item.quantityLabel} is on hand and all of it is '
          'already committed to other jobs.';
    }
    if (_job == null) return 'Choose the job this stock is for.';
    if (_qty <= 0) return 'Enter how much to reserve.';
    if (_item.isSerialized && _qty != 1) {
      return '${_item.code} is a single serialised stone. It is reserved as one or not at all.';
    }
    if (_qty > _available) {
      return 'Only ${_item.availableLabel} is free. Reduce the quantity, or release another '
          "job's reservation first.";
    }
    return null;
  }

  Future<void> _submit() async {
    final job = _job;
    if (job == null || _blockReason != null) return;

    // Issuing posts an append-only movement — UPDATE and DELETE are revoked on
    // `stock_transactions` — so it is confirmed before it is posted, while reserving is not:
    // a reservation can be released.
    if (_issueNow) {
      final agreed = await confirmAction(
        context,
        title: 'Issue ${qtyLabel(_qty, _item.uom)} now?',
        message: 'This takes ${_item.code} out of the vault and onto ${job.displayCode}. The '
            'movement is part of the permanent ledger — a mistake is corrected by returning the '
            'stock, never by editing the row.',
        confirmLabel: 'Reserve and issue',
        cancelLabel: 'Just reserve it',
      );
      if (!mounted) return;
      if (!agreed) {
        // Backing out of the confirm means "reserve only", not "do nothing" — but the keeper has
        // to press again, because the button now does something different.
        setState(() => _issueNow = false);
        return;
      }
    }

    final actions = ref.read(inventoryActionsProvider.notifier);
    try {
      final allocation = await actions.allocate(
        item: _item,
        jobId: job.id,
        qty: _qty,
        stoneId: _stone?.id,
      );
      if (_issueNow) {
        await actions.issue(
          allocation,
          stage: job.currentStage,
          note: 'Issued at the vault counter for ${job.displayCode}',
        );
      }
      if (!mounted) return;
      // The message goes up before the sheet comes down: after the pop this context is
      // deactivated, and looking up the ScaffoldMessenger through it is then unsafe.
      showDone(
        context,
        _issueNow
            ? '${qtyLabel(_qty, _item.uom)} of ${_item.code} issued to ${job.displayCode}.'
            : '${qtyLabel(_qty, _item.uom)} of ${_item.code} reserved for ${job.displayCode}.',
      );
      Navigator.of(context).pop(allocation);
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = ref.watch(inventoryActionsProvider) != null;
    final blocked = _blockReason;
    final job = _job;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Assign stock', style: context.text.headlineSmall),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    'Reserving holds this stock for one job. It stays on the shelf until someone '
                    'issues it.',
                    style: context.text.bodySmall
                        ?.copyWith(color: context.scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.sm, Spacing.md, Spacing.md),
                children: [
                  _ItemSummary(item: _item),
                  const SizedBox(height: Spacing.md),
                  const VaultHeading('Job'),
                  const SizedBox(height: Spacing.sm),
                  SelectableTile(
                    title: job?.displayCode ?? 'Choose a job',
                    blurb: job == null
                        ? 'Committed jobs only — a draft has no bench waiting on it.'
                        : [
                            job.displayTitle,
                            if (job.customerName != null) job.customerName!,
                          ].join(' · '),
                    icon: Icons.work_outline_rounded,
                    selected: job != null,
                    onTap: busy
                        ? null
                        : () => unawaited(
                              _chooseJob(context),
                            ),
                  ),
                  if (job != null) ...[
                    const SizedBox(height: Spacing.md),
                    _StoneLinePicker(
                      jobId: job.id,
                      item: _item,
                      selected: _stone,
                      enabled: !busy,
                      onChanged: (stone) => setState(() => _stone = stone),
                    ),
                  ],
                  const SizedBox(height: Spacing.md),
                  const VaultHeading('Quantity'),
                  const SizedBox(height: Spacing.sm),
                  if (_item.isSerialized)
                    const VaultNote(
                      icon: Icons.diamond_outlined,
                      text: 'A serialised stone is one object. It is reserved whole — there is no '
                          'half of this stone.',
                    )
                  else if (_available <= 0)
                    const VaultNote(
                      tone: VaultNoteTone.risk,
                      text: 'Nothing is free to reserve.',
                    )
                  else
                    StepperField(
                      value: _qty,
                      min: 0,
                      max: _available,
                      step: stepFor(_item.uom),
                      decimals: decimalsFor(_item.uom),
                      unit: _item.uom.symbol,
                      label: 'Reserve',
                      helperText: '${_item.availableLabel} free of ${_item.quantityLabel} on hand',
                      enabled: !busy,
                      onChanged: (value) => setState(() => _qty = value),
                    ),
                  const SizedBox(height: Spacing.md),
                  ToggleTile(
                    title: 'Issue it from the vault now',
                    blurb: 'Tick this if the stock is leaving the shelf with you. It posts the '
                        'movement that takes it off the balance.',
                    value: _issueNow,
                    enabled: !busy,
                    onChanged: (value) => setState(() => _issueNow = value),
                  ),
                ],
              ),
            ),
            VaultFooter(
              blockedReason: blocked,
              note: _issueNow
                  ? 'The movement goes onto the permanent ledger.'
                  : 'You can release a reservation at any time.',
              children: [
                FilledButton.icon(
                  onPressed: blocked == null && !busy ? () => unawaited(_submit()) : null,
                  icon: busy
                      ? const VaultSpinner()
                      : Icon(_issueNow ? Icons.output_rounded : Icons.bookmark_added_outlined),
                  label: Text(
                    job == null
                        ? 'Reserve stock'
                        : _issueNow
                            ? 'Reserve and issue to ${job.displayCode}'
                            : 'Reserve for ${job.displayCode}',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseJob(BuildContext context) async {
    final picked = await pickJobSheet(
      context,
      title: 'Which job is this stock for?',
      blurb: 'Search by job code, title or customer.',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _job = picked;
      // A stone line belongs to one job. Keeping the old line selected after the job changed
      // would post the allocation against a line on a different order.
      _stone = null;
    });
  }
}

/// The item being assigned, restated so the keeper is never guessing which tray this sheet is
/// about.
final class _ItemSummary extends StatelessWidget {
  const _ItemSummary({required this.item});

  final InventoryItem item;

  @override
  Widget build(BuildContext context) => DhCard(
        tone: DhCardTone.inset,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusChip.code(item.code, dense: true),
                const SizedBox(width: Spacing.sm),
                if (item.stoneOrigin != null)
                  StatusChip.origin(item.stoneOrigin!, dense: true),
                const Spacer(),
                Text(
                  item.availableLabel,
                  style: AppTheme.mono(
                    size: 13,
                    weight: FontWeight.w600,
                    color: context.scheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            Text(item.label, style: context.text.titleMedium),
            const SizedBox(height: 2),
            Text(
              item.gradeSummary,
              style: AppTheme.mono(size: 11.5, color: context.scheme.onSurfaceVariant),
            ),
            if (item.location != null) ...[
              const SizedBox(height: Spacing.sm),
              Row(
                children: [
                  Icon(
                    Icons.place_outlined,
                    size: 14,
                    color: context.scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    item.location!,
                    style: AppTheme.mono(size: 10.5, color: context.scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
}

/// Which stone line on the job this reservation satisfies.
///
/// Optional by design: a bench pulling 0.4 g of solder is not satisfying a stone line, and
/// forcing a choice would make the keeper invent one.
final class _StoneLinePicker extends ConsumerWidget {
  const _StoneLinePicker({
    required this.jobId,
    required this.item,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final String jobId;
  final InventoryItem item;
  final Stone? selected;
  final bool enabled;
  final ValueChanged<Stone?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(allocatableStoneLinesProvider(jobId: jobId, item: item));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const VaultHeading('Stone line'),
        const SizedBox(height: Spacing.sm),
        switch (lines) {
          AsyncValue(value: final rows?) when rows.isEmpty => VaultNote(
              text: 'This job has no stone line that ${item.code} could satisfy. The reservation '
                  'is recorded against the job itself.',
            ),
          AsyncValue(value: final rows?) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final stone in rows) ...[
                  SelectableTile(
                    title: stone.displayTitle,
                    blurb: stone.gradeSummary,
                    icon: Icons.diamond_outlined,
                    selected: selected?.id == stone.id,
                    inGroup: true,
                    enabled: enabled,
                    badge: stone.inventoryItemId == null
                        ? null
                        : const StatusChip(
                            label: 'Already allocated',
                            tone: ChipTone.warning,
                            dense: true,
                          ),
                    onTap: () => onChanged(selected?.id == stone.id ? null : stone),
                  ),
                  const SizedBox(height: Spacing.sm),
                ],
                if (selected != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: enabled ? () => onChanged(null) : null,
                      icon: const Icon(Icons.close_rounded, size: 16),
                      label: const Text('No specific line'),
                    ),
                  ),
              ],
            ),
          AsyncError(error: final error) => VaultNote(
              tone: VaultNoteTone.risk,
              text: error is DhFailure
                  ? error.message
                  : 'The stone lines on this job could not be read. The reservation can still be '
                      'made against the job.',
            ),
          _ => const LoadingSkeleton.lines(count: 2),
        },
      ],
    );
  }
}

// ================================================================= job picker

final class _JobPickerSheet extends ConsumerStatefulWidget {
  const _JobPickerSheet({required this.title, required this.blurb});

  final String title;
  final String blurb;

  @override
  ConsumerState<_JobPickerSheet> createState() => _JobPickerSheetState();
}

class _JobPickerSheetState extends ConsumerState<_JobPickerSheet> {
  final TextEditingController _search = TextEditingController();
  String? _query;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = value.trim().isEmpty ? null : value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final jobs = ref.watch(allocatableJobsProvider(_query));

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title, style: context.text.headlineSmall),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    widget.blurb,
                    style: context.text.bodySmall
                        ?.copyWith(color: context.scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: Spacing.md),
                  TextField(
                    controller: _search,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onChanged: _onChanged,
                    decoration: const InputDecoration(
                      hintText: 'Job code, title or customer',
                      isDense: true,
                      prefixIcon: Icon(Icons.search_rounded, size: 20),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: switch (jobs) {
                AsyncValue(value: final rows?) when rows.isEmpty => Padding(
                    padding: const EdgeInsets.all(Spacing.md),
                    child: EmptyState(
                      compact: true,
                      icon: Icons.work_off_outlined,
                      title: _query == null ? 'No committed jobs' : 'No job matches',
                      message: _query == null
                          ? 'Stock is reserved against committed work. Commit a job order and it '
                              'appears here.'
                          : 'Nothing open matches "$_query". Search by job code, title or '
                              'customer.',
                    ),
                  ),
                AsyncValue(value: final rows?) => ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(
                      Spacing.md,
                      Spacing.sm,
                      Spacing.md,
                      Spacing.md,
                    ),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: Spacing.sm),
                    itemBuilder: (context, index) {
                      final job = rows[index];
                      return SelectableTile(
                        title: job.displayCode,
                        blurb: [
                          job.displayTitle,
                          if (job.customerName != null) job.customerName!,
                          job.currentStage?.label ?? 'not started',
                        ].join(' · '),
                        icon: Icons.work_outline_rounded,
                        badge: PriorityChip(job.priority, dense: true, showStandard: false),
                        onTap: () => Navigator.of(context).pop(job),
                      );
                    },
                  ),
                AsyncError(error: final error) => Padding(
                    padding: const EdgeInsets.all(Spacing.md),
                    child: ErrorState(
                      compact: true,
                      title: 'The job list did not load',
                      message: error is DhFailure
                          ? error.message
                          : 'Check the connection and try again.',
                      detail: error is DhFailure ? error.detail : null,
                      onRetry: () => ref.invalidate(allocatableJobsProvider(_query)),
                    ),
                  ),
                _ => const Padding(
                    padding: EdgeInsets.all(Spacing.md),
                    child: LoadingSkeleton.list(count: 3),
                  ),
              },
            ),
          ],
        ),
      ),
    );
  }
}
