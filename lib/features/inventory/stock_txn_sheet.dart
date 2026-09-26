/// Movements: receive, issue, return, adjust and **scrap**.
///
/// Nothing in the 46 mockups could record a movement. That is not a small omission — the corpus's
/// own dashboard carried the alert "Stones missing for DH-1061 — Melee diamonds count mismatch at
/// receiving", so the designs knew reconciliation was a live problem and offered no screen that
/// could answer it.
///
/// Two facts about this sheet follow from the schema and are worth stating plainly, because they
/// change how it behaves:
///
///   * **`stock_transactions` is append-only.** UPDATE and DELETE are revoked in Postgres. A
///     posted row cannot be edited or withdrawn — a mistake is corrected by a compensating
///     movement. So the acts that take stock away are confirmed before they are posted, and the
///     confirm says exactly that.
///   * **Scrap is a first-class kind.** Jewellery loses measurable metal to filings, polishing and
///     casting sprues. A shop that cannot book that loss has a balance that drifts until someone
///     writes off the difference and calls it shrinkage, and the sprue is not shrinkage — it is a
///     known, weighable, recoverable quantity.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/customer_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/inventory/allocate_sheet.dart';
import 'package:dhanaos/features/inventory/inventory_actions.dart';
import 'package:dhanaos/features/inventory/inventory_widgets.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// Post a movement against [item]. Returns the transaction when one was posted.
Future<StockTransaction?> showStockTxnSheet(
  BuildContext context, {
  required InventoryItem item,
  StockTxnKind initialKind = StockTxnKind.receive,
  JobListItem? job,
}) =>
    showModalBottomSheet<StockTransaction>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
        child: _StockTxnSheet(item: item, initialKind: initialKind, initialJob: job),
      ),
    );

/// The five movements an operator can post, in the order the day runs: stock arrives, goes out,
/// comes back, is counted, and is lost.
///
/// `allocate` and `release` are absent on purpose. They are reservation states, not movements —
/// they belong to the Assign sheet, and posting one here would count the same gram twice against
/// `inv_alloc_sane`.
const _kinds = <StockTxnKind>[
  StockTxnKind.receive,
  StockTxnKind.issue,
  StockTxnKind.returned,
  StockTxnKind.adjust,
  StockTxnKind.scrap,
];

/// What each movement means on the shop floor, in the operator's language.
String _blurbFor(StockTxnKind kind) => switch (kind) {
      StockTxnKind.receive => 'A parcel arrived from a supplier. Enter what it cost and this '
          'becomes the valuation behind every job that uses it.',
      StockTxnKind.issue => 'Stock leaving the vault for a job, without a prior reservation — a '
          'bench pulling half a gram of solder.',
      StockTxnKind.returned => 'Unused metal or a rejected stone coming back to the shelf.',
      StockTxnKind.adjust => 'A stock-take correction. Say what the count found — an unexplained '
          'adjustment reads as a missing stone six weeks later.',
      StockTxnKind.scrap => 'Filings, polishing loss and casting sprues. Metal that will not come '
          'back, booked so the month-end reconciles.',
      StockTxnKind.allocate || StockTxnKind.release => 'A reservation, not a movement.',
    };

IconData _iconFor(StockTxnKind kind) => switch (kind) {
      StockTxnKind.receive => Icons.south_west_rounded,
      StockTxnKind.issue => Icons.north_east_rounded,
      StockTxnKind.returned => Icons.undo_rounded,
      StockTxnKind.adjust => Icons.balance_rounded,
      StockTxnKind.scrap => Icons.delete_sweep_outlined,
      StockTxnKind.allocate => Icons.bookmark_border_rounded,
      StockTxnKind.release => Icons.bookmark_remove_outlined,
    };

final class _StockTxnSheet extends ConsumerStatefulWidget {
  const _StockTxnSheet({
    required this.item,
    required this.initialKind,
    this.initialJob,
  });

  final InventoryItem item;
  final StockTxnKind initialKind;
  final JobListItem? initialJob;

  @override
  ConsumerState<_StockTxnSheet> createState() => _StockTxnSheetState();
}

class _StockTxnSheetState extends ConsumerState<_StockTxnSheet> {
  late StockTxnKind _kind = widget.initialKind;
  late JobListItem? _job = widget.initialJob;
  late Money _unitCost = widget.item.unitCost ?? Money(0, widget.item.currency);

  final TextEditingController _note = TextEditingController();
  final TextEditingController _reference = TextEditingController();
  final TextEditingController _lot = TextEditingController();

  Partner? _supplier;

  /// Magnitude. Direction comes from the kind, or from [_found] for an adjustment.
  double _qty = 1;

  /// Adjustment direction: a count that found more than the books say, or less.
  bool _found = false;

  /// Whether a receive also rewrites the item's unit cost. The ledger row keeps the historic
  /// price whatever this is set to.
  late bool _repriceItem = widget.item.unitCost == null;

  InventoryItem get _item => widget.item;

  @override
  void initState() {
    super.initState();
    _qty = _item.isSerialized ? 1 : _defaultQty();
  }

  double _defaultQty() => switch (_kind) {
        // Taking stock out cannot sensibly start above what is free.
        StockTxnKind.issue || StockTxnKind.scrap =>
          _item.qtyAvailable < 1 ? _item.qtyAvailable : 1,
        _ => 1,
      };

  @override
  void dispose() {
    _note.dispose();
    _reference.dispose();
    _lot.dispose();
    super.dispose();
  }

  bool get _isOutbound => _kind == StockTxnKind.issue || _kind == StockTxnKind.scrap;

  bool get _needsJob => _kind == StockTxnKind.issue;

  /// Signed quantity as it will reach the ledger. Only `adjust` carries the operator's own sign;
  /// every other kind takes its direction from [StockTxnKind.sign].
  double get _signed => _kind == StockTxnKind.adjust ? (_found ? _qty : -_qty) : _qty;

  /// Convention 8: say what is missing and how to fix it, above a shut button.
  String? get _blockReason {
    if (_qty <= 0) return 'Enter a quantity. A movement of zero records nothing.';
    if (_item.isSerialized && _qty != 1 && _kind != StockTxnKind.adjust) {
      return '${_item.code} is a single serialised stone — movements are of one, or of none.';
    }
    if (_needsJob && _job == null) {
      return 'Choose the job this stock is going to. An issue with no job cannot be costed.';
    }
    if (_isOutbound && _qty > _item.qtyOnHand) {
      return 'Only ${_item.quantityLabel} is on hand. Count the tray and post an adjustment '
          'first — the balance cannot go below zero.';
    }
    if (_kind == StockTxnKind.adjust && _note.text.trim().isEmpty) {
      // The repository refuses this too. Holding the button shut is friendlier than firing a
      // request that is certain to come back refused.
      return 'Say what the count found. An adjustment with no reason reads as a missing stone '
          'later.';
    }
    if (_kind == StockTxnKind.scrap && _note.text.trim().isEmpty) {
      return 'Say where the metal went — filings, sprue, polishing loss. A scrap row with no '
          'reason is indistinguishable from a loss at month end.';
    }
    return null;
  }

  /// Only the acts that take stock away are confirmed. Receive and return are additive and a
  /// mis-keyed receive is corrected by an adjustment with a reason on it; an issue or a scrap has
  /// already told a bench that the metal is theirs.
  bool get _needsConfirm =>
      _isOutbound || (_kind == StockTxnKind.adjust && !_found);

  Future<void> _submit() async {
    if (_blockReason != null) return;

    if (_needsConfirm) {
      final agreed = await confirmAction(
        context,
        title: '${_kind.label} ${qtyLabel(_qty, _item.uom)} of ${_item.code}?',
        message: _kind == StockTxnKind.scrap
            ? 'Scrapped metal does not come back. The row goes onto the permanent ledger and '
                'shows up in this item’s loss figure.'
            : 'The movement is appended to the permanent ledger. It cannot be edited or deleted '
                'afterwards — a mistake is corrected with a second movement.',
        confirmLabel: 'Post the ${_kind.label.toLowerCase()}',
        destructive: _kind == StockTxnKind.scrap,
      );
      if (!mounted || !agreed) return;
    }

    final actions = ref.read(inventoryActionsProvider.notifier);
    try {
      final txn = _kind == StockTxnKind.adjust
          ? await actions.adjust(
              itemId: _item.id,
              delta: _signed,
              note: _note.text,
              reference: _reference.text.trim().isEmpty ? null : _reference.text,
            )
          : await actions.move(
              itemId: _item.id,
              kind: _kind,
              qty: _qty,
              jobId: _job?.id,
              // Attribute consumption to where the job actually stands, so a cost analysis can
              // tell casting loss from setting loss.
              stage: _job?.currentStage,
              unitCost: _kind == StockTxnKind.receive && !_unitCost.isZero ? _unitCost : null,
              supplierId: _supplier?.id,
              lotRef: _lot.text,
              reference: _reference.text,
              note: _note.text,
            );

      // The item's own unit cost is a separate column from the movement's. Rewriting it is a
      // valuation decision, so it is the operator's tick — and the ledger keeps both prices
      // either way.
      if (_kind == StockTxnKind.receive && _repriceItem && !_unitCost.isZero) {
        await actions.editItem(
          itemId: _item.id,
          unitCost: _unitCost,
          supplierId: _supplier?.id,
          lotRef: _lot.text.trim().isEmpty ? null : _lot.text,
        );
      }

      if (!mounted) return;
      // Message first, then the pop: this context is deactivated once the sheet is gone, and
      // reaching the ScaffoldMessenger through a deactivated context is unsafe.
      showDone(context, _doneMessage(txn));
      Navigator.of(context).pop(txn);
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  String _doneMessage(StockTransaction txn) {
    final moved = signedQtyLabel(txn.qty, _item.uom);
    return switch (_kind) {
      StockTxnKind.receive => '$moved received into ${_item.code}.',
      StockTxnKind.issue => '$moved issued to ${_job?.displayCode ?? 'the job'}.',
      StockTxnKind.returned => '$moved returned to ${_item.code}.',
      StockTxnKind.adjust => 'Count corrected by $moved on ${_item.code}.',
      StockTxnKind.scrap => '$moved scrapped from ${_item.code}.',
      StockTxnKind.allocate || StockTxnKind.release => 'Movement posted.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final busy = ref.watch(inventoryActionsProvider) != null;
    final blocked = _blockReason;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Move stock', style: context.text.headlineSmall),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    '${_item.code} · ${_item.label} · ${_item.quantityLabel} on hand',
                    style: AppTheme.mono(size: 11.5, color: context.scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(
                  Spacing.md,
                  Spacing.sm,
                  Spacing.md,
                  Spacing.md,
                ),
                children: [
                  Wrap(
                    spacing: Spacing.sm,
                    runSpacing: Spacing.sm,
                    children: [
                      for (final kind in _kinds)
                        FilterChip(
                          avatar: Icon(_iconFor(kind), size: 16),
                          label: Text(kind.label),
                          selected: _kind == kind,
                          showCheckmark: false,
                          onSelected: busy
                              ? null
                              : (_) => setState(() {
                                    _kind = kind;
                                    _qty = _item.isSerialized ? 1 : _defaultQty();
                                    if (!_needsJob) _job = widget.initialJob;
                                  }),
                        ),
                    ],
                  ),
                  const SizedBox(height: Spacing.md),
                  VaultNote(
                    tone: _kind == StockTxnKind.scrap
                        ? VaultNoteTone.risk
                        : VaultNoteTone.info,
                    icon: _iconFor(_kind),
                    text: _blurbFor(_kind),
                  ),
                  const SizedBox(height: Spacing.md),

                  // ---------------------------------------------------- quantity
                  if (_kind == StockTxnKind.adjust) ...[
                    const VaultHeading('What did the count find?'),
                    const SizedBox(height: Spacing.sm),
                    DhSegmented<bool>(
                      value: _found,
                      onChanged: (value) {
                        if (busy) return;
                        setState(() => _found = value);
                      },
                      segments: const [
                        DhSegment(
                          value: false,
                          label: 'Short',
                          icon: Icons.trending_down_rounded,
                        ),
                        DhSegment(value: true, label: 'Found', icon: Icons.trending_up_rounded),
                      ],
                    ),
                    const SizedBox(height: Spacing.md),
                  ],
                  if (_item.isSerialized && _kind != StockTxnKind.adjust)
                    VaultNote(
                      icon: Icons.diamond_outlined,
                      text: 'One serialised stone moves as one. ${_item.code} is the stone.',
                    )
                  else
                    StepperField(
                      value: _qty,
                      min: 0,
                      // A stock-take can find more than the books say, so an adjustment is not
                      // capped by the balance. Everything else is.
                      max: _isOutbound
                          ? (_item.qtyOnHand <= 0 ? 0.001 : _item.qtyOnHand)
                          : 9999,
                      step: stepFor(_item.uom),
                      decimals: decimalsFor(_item.uom),
                      unit: _item.uom.symbol,
                      label: _kind == StockTxnKind.adjust
                          ? (_found ? 'Found' : 'Short by')
                          : 'Quantity',
                      helperText: _isOutbound
                          ? '${_item.quantityLabel} on hand, ${_item.availableLabel} free'
                          : null,
                      enabled: !busy,
                      onChanged: (value) => setState(() => _qty = value),
                    ),
                  const SizedBox(height: Spacing.md),

                  // ---------------------------------------------------- job
                  if (_kind != StockTxnKind.receive && _kind != StockTxnKind.adjust) ...[
                    VaultHeading(_needsJob ? 'Job' : 'Job (optional)'),
                    const SizedBox(height: Spacing.sm),
                    SelectableTile(
                      title: _job?.displayCode ?? 'Choose a job',
                      blurb: _job == null
                          ? _needsJob
                              ? 'An issue is costed to a job, so this one is required.'
                              : 'Attach the movement to a job when it belongs to one.'
                          : [
                              _job!.displayTitle,
                              if (_job!.currentStage != null) _job!.currentStage!.label,
                            ].join(' · '),
                      icon: Icons.work_outline_rounded,
                      selected: _job != null,
                      onTap: busy ? null : () => unawaited(_chooseJob(context)),
                      trailing: _job == null
                          ? null
                          : IconButton(
                              tooltip: 'Clear the job',
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: busy || _needsJob
                                  ? null
                                  : () => setState(() => _job = null),
                            ),
                    ),
                    const SizedBox(height: Spacing.md),
                  ],

                  // ---------------------------------------------------- costing
                  if (_kind == StockTxnKind.receive) ...[
                    const VaultHeading('Costing'),
                    const SizedBox(height: Spacing.sm),
                    MoneyField(
                      value: _unitCost,
                      label: 'Unit cost per ${_item.uom.symbol}',
                      helperText: 'What the parcel cost. Without it, nothing downstream can value '
                          'this stock — the mockups had no costing field at all.',
                      enabled: !busy,
                      // D-004: INR primary, USD supported. A parcel bought in dollars is entered
                      // in dollars, not converted by hand at the counter.
                      onCurrencyChanged: (code) =>
                          setState(() => _unitCost = Money(_unitCost.minor, code)),
                      onChanged: (value) => setState(() => _unitCost = value),
                    ),
                    const SizedBox(height: Spacing.sm),
                    if (!_unitCost.isZero)
                      ToggleTile(
                        title: 'Use this as the item’s unit cost',
                        blurb: _item.unitCost == null
                            ? 'Nothing values ${_item.code} yet, so this price becomes its '
                                'valuation.'
                            : 'Replaces ${_item.unitCost!.format()} per ${_item.uom.symbol}. The '
                                'ledger keeps both prices.',
                        value: _repriceItem,
                        enabled: !busy,
                        tone: VaultNoteTone.consequence,
                        onChanged: (value) => setState(() => _repriceItem = value),
                      ),
                    const SizedBox(height: Spacing.md),
                    _SupplierPicker(
                      selected: _supplier,
                      enabled: !busy,
                      onChanged: (partner) => setState(() => _supplier = partner),
                    ),
                    const SizedBox(height: Spacing.md),
                    TextField(
                      controller: _lot,
                      enabled: !busy,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [_UpperCase()],
                      style: AppTheme.mono(size: 14),
                      decoration: const InputDecoration(
                        labelText: 'Lot reference',
                        hintText: 'LOT-2026-114',
                        helperText: 'The supplier’s parcel id, so a later dispute can be '
                            'traced to one delivery.',
                      ),
                    ),
                    const SizedBox(height: Spacing.md),
                  ],

                  // ---------------------------------------------------- paperwork
                  TextField(
                    controller: _reference,
                    enabled: !busy,
                    style: AppTheme.mono(size: 14),
                    decoration: InputDecoration(
                      labelText: switch (_kind) {
                        StockTxnKind.receive => 'Invoice or GRN number',
                        StockTxnKind.adjust => 'Stock-take reference',
                        _ => 'Reference (optional)',
                      },
                      hintText: 'GRN-2026-00184',
                    ),
                  ),
                  const SizedBox(height: Spacing.md),
                  TextField(
                    controller: _note,
                    enabled: !busy,
                    minLines: 2,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: switch (_kind) {
                        StockTxnKind.adjust => 'What the count found',
                        StockTxnKind.scrap => 'Where the metal went',
                        _ => 'Note (optional)',
                      },
                      alignLabelWithHint: true,
                      hintText: switch (_kind) {
                        StockTxnKind.adjust => 'Tray 4 recount: 0.6 g less than the books.',
                        StockTxnKind.scrap => 'Sprue and filings from the casting run.',
                        StockTxnKind.issue => 'Pulled for the setter.',
                        _ => null,
                      },
                    ),
                  ),
                ],
              ),
            ),
            VaultFooter(
              blockedReason: blocked,
              note: _needsConfirm
                  ? 'You will be asked to confirm — the ledger cannot be edited afterwards.'
                  : 'The movement is appended to the ledger and the balance follows it.',
              children: [
                FilledButton.icon(
                  onPressed: blocked == null && !busy ? () => unawaited(_submit()) : null,
                  icon: busy ? const VaultSpinner() : Icon(_iconFor(_kind)),
                  label: Text('${_kind.label} ${qtyLabel(_qty, _item.uom)}'),
                  style: _kind == StockTxnKind.scrap
                      ? FilledButton.styleFrom(
                          backgroundColor: context.scheme.error,
                          foregroundColor: context.scheme.onError,
                        )
                      : null,
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
      title: 'Which job is this for?',
      blurb: 'Search by job code, title or customer.',
    );
    if (picked == null || !mounted) return;
    setState(() => _job = picked);
  }
}

// ================================================================= supplier

/// Who the parcel came from. Optional, but it is what turns a price into a traceable purchase.
final class _SupplierPicker extends StatelessWidget {
  const _SupplierPicker({
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final Partner? selected;
  final bool enabled;
  final ValueChanged<Partner?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const VaultHeading('Supplier (optional)'),
        const SizedBox(height: Spacing.sm),
        SelectableTile(
          title: selected?.name ?? 'Choose a supplier',
          blurb: selected == null
              ? 'A named supplier is what makes a price traceable to a delivery.'
              : selected!.kind.label,
          icon: Icons.local_shipping_outlined,
          selected: selected != null,
          onTap: enabled ? () => unawaited(_pick(context)) : null,
          trailing: selected == null
              ? null
              : IconButton(
                  tooltip: 'Clear the supplier',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: enabled ? () => onChanged(null) : null,
                ),
        ),
      ],
    );
  }

  Future<void> _pick(BuildContext context) async {
    final chosen = await showModalBottomSheet<Partner>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _SupplierSheet(),
    );
    if (chosen != null) onChanged(chosen);
  }
}

/// The directory itself, as its own consumer: a provider must be watched inside a build method,
/// and a `showModalBottomSheet` builder is not one.
final class _SupplierSheet extends ConsumerWidget {
  const _SupplierSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final directory = ref.watch(partnerDirectoryProvider(null));

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
              child: Text('Supplier', style: context.text.headlineSmall),
            ),
            Flexible(
              child: switch (directory) {
                AsyncValue(value: final rows?) when rows.isEmpty => const Padding(
                    padding: EdgeInsets.all(Spacing.md),
                    child: EmptyState(
                      compact: true,
                      icon: Icons.storefront_outlined,
                      title: 'No partners yet',
                      message: 'Add a supplier in Settings and it appears here. The movement can '
                          'be posted without one.',
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
                    itemBuilder: (context, index) => SelectableTile(
                      title: rows[index].name,
                      blurb: rows[index].kind.label,
                      icon: Icons.local_shipping_outlined,
                      onTap: () => Navigator.of(context).pop(rows[index]),
                    ),
                  ),
                AsyncError(error: final error) => Padding(
                    padding: const EdgeInsets.all(Spacing.md),
                    child: ErrorState(
                      compact: true,
                      title: 'The partner list did not load',
                      message: error is DhFailure
                          ? error.message
                          : 'Check the connection and try again.',
                      onRetry: () => ref.invalidate(partnerDirectoryProvider(null)),
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

/// Lot and reference codes are identifiers — they are stored and compared, so they are upper-cased
/// as they are typed rather than being cleaned up later.
final class _UpperCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue value) =>
      TextEditingValue(text: value.text.toUpperCase(), selection: value.selection);
}
