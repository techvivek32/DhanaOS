/// One cost line, added or amended.
///
/// `commercial_requirements` is the least-evolved screen in the corpus: it had no inputs at all.
/// Its four hardcoded charges summed to $970, a figure no screen ever displayed, while the
/// pricing-approval screen a folder away showed $4,850 for the same job. D-003 replaces those
/// four lines with the five customer-facing categories a customer actually approves, and this
/// sheet is where a line is written.
///
/// Two things the sheet gets right that no mockup attempted:
///
///  * **A client-owned line is not a charge.** It carries a declared value for insurance and is
///    excluded from the subtotal and from GST — the workshop cannot invoice a customer for the
///    customer's own diamond.
///  * **The amount is computed, never typed twice.** Quantity times unit price is shown live, so
///    14.2 g at ₹6,400 reads back as ₹90,880 before the line is saved.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// Opens the editor. Writes through [controller] and returns once the write has settled.
Future<void> showCostLineSheet(
  BuildContext context, {
  required IntakeController controller,
  required String currency,
  CostLine? line,
  CostCategory category = CostCategory.metal,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: _CostLineSheet(
        controller: controller,
        currency: currency,
        line: line,
        category: line?.category ?? category,
      ),
    ),
  );
}

final class _CostLineSheet extends StatefulWidget {
  const _CostLineSheet({
    required this.controller,
    required this.currency,
    required this.category,
    this.line,
  });

  final IntakeController controller;
  final String currency;
  final CostCategory category;
  final CostLine? line;

  @override
  State<_CostLineSheet> createState() => _CostLineSheetState();
}

class _CostLineSheetState extends State<_CostLineSheet> {
  late CostCategory _category = widget.category;
  late String _label = widget.line?.label ?? '';
  late String _detail = widget.line?.detail ?? '';
  late double _qty = widget.line?.qty ?? 1;
  late Uom _unit = widget.line?.unit ?? _defaultUnitFor(widget.category);
  late SuppliedBy _suppliedBy = widget.line?.suppliedBy ?? SuppliedBy.house;
  late Money _unitAmount =
      widget.line?.unitAmountIn(widget.currency) ?? Money(0, widget.currency);
  late Money _declared =
      widget.line?.declaredValueIn(widget.currency) ?? Money(0, widget.currency);
  bool _busy = false;

  bool get _isNew => widget.line == null;

  /// Client-supplied material is held, not sold. The two flags move together so a line can never
  /// be "client supplied" and still land on the invoice.
  bool get _clientOwned => _suppliedBy.isClient;

  Money get _amount => _unitAmount * _qty;

  static Uom _defaultUnitFor(CostCategory category) => switch (category) {
        CostCategory.metal => Uom.gram,
        CostCategory.gemstones => Uom.carat,
        CostCategory.labor || CostCategory.setting || CostCategory.certification => Uom.piece,
      };

  String? get _blockReason {
    if (_label.trim().isEmpty) {
      return 'Name the charge. A cost line with no label is unreadable on an invoice.';
    }
    if (_clientOwned && (_declared.isZero || _declared.isNegative)) {
      return 'Enter what the client\'s material is worth. It is not charged, but it has to be '
          'insured.';
    }
    if (!_clientOwned && _unitAmount.isZero) {
      return 'Enter the unit price. A zero line adds nothing to the quote and confuses the '
          'customer reading it.';
    }
    return null;
  }

  Future<void> _save() async {
    if (_blockReason != null || _busy) return;
    setState(() => _busy = true);
    final failure = _isNew
        ? await widget.controller.addCostLine(
            category: _category,
            label: _label,
            detail: _detail,
            qty: _qty,
            unit: _unit,
            suppliedBy: _suppliedBy,
            isClientOwned: _clientOwned,
            // Zero on the invoice, real on the insurance schedule.
            unitAmount: _clientOwned ? Money(0, widget.currency) : _unitAmount,
            declaredValue: _clientOwned ? _declared : null,
          )
        : await widget.controller.updateCostLine(
            lineId: widget.line!.id,
            category: _category,
            label: _label,
            detail: _detail,
            qty: _qty,
            unit: _unit,
            suppliedBy: _suppliedBy,
            isClientOwned: _clientOwned,
            unitAmount: _clientOwned ? Money(0, widget.currency) : _unitAmount,
            declaredValue: _clientOwned ? _declared : null,
          );
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) {
      showFailure(context, failure);
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.line;
    if (existing == null) return;
    final confirmed = await confirmAction(
      context,
      title: 'Remove "${existing.label}"?',
      message: 'The charge comes off the quote and the totals recalculate.',
      confirmLabel: 'Remove the line',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    final failure = await widget.controller.removeCostLine(existing.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) {
      showFailure(context, failure);
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _blockReason;

    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.92,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
              child: Text(
                _isNew ? 'Add a cost line' : 'Edit cost line',
                style: context.text.headlineSmall?.copyWith(color: context.scheme.onSurface),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.md),
                children: [
                  FieldBlock(
                    label: 'Category',
                    helper: 'D-003: the five headings the customer approves. Everything the '
                        'workshop tracks internally rolls up into one of them.',
                    child: ChoiceWrap<CostCategory>(
                      values: CostCategory.values,
                      selected: _category,
                      labelOf: (value) => value.label,
                      onSelected: (value) => setState(() {
                        _category = value;
                        if (_isNew) _unit = _defaultUnitFor(value);
                      }),
                    ),
                  ),
                  const Gap.md(),
                  IntakeTextField(
                    value: _label,
                    label: 'What the charge is',
                    hint: _hintFor(_category),
                    onChanged: (value) => setState(() => _label = value),
                  ),
                  const Gap.md(),
                  IntakeTextField(
                    value: _detail,
                    label: 'Detail',
                    hint: '18K white gold, 14.2 g at today\'s rate',
                    helper: 'Printed under the line on the customer\'s copy.',
                    onChanged: (value) => setState(() => _detail = value),
                  ),
                  const Gap.md(),
                  FieldBlock(
                    label: 'Who supplies it',
                    child: DhSegmented<SuppliedBy>(
                      value: _suppliedBy,
                      segments: const [
                        DhSegment(
                          value: SuppliedBy.house,
                          label: 'Workshop',
                          icon: Icons.storefront_outlined,
                        ),
                        DhSegment(
                          value: SuppliedBy.client,
                          label: 'Client',
                          icon: Icons.shield_outlined,
                        ),
                      ],
                      onChanged: (value) => setState(() => _suppliedBy = value),
                    ),
                  ),
                  const Gap.md(),
                  if (_clientOwned) ...[
                    const NoteStrip(
                      tone: NoteTone.consequence,
                      icon: Icons.shield_outlined,
                      text: 'A client\'s own material is not charged. This line carries a '
                          'declared value so it appears on the insurance schedule and on the '
                          'goods-in record — and it is excluded from the subtotal and from GST.',
                    ),
                    const Gap.md(),
                    MoneyField(
                      value: _declared,
                      label: 'Declared value',
                      helperText: 'What the client says the material is worth.',
                      onChanged: (value) => setState(() => _declared = value),
                    ),
                  ] else ...[
                    StepperField(
                      value: _qty,
                      min: _unit == Uom.piece ? 1 : 0.01,
                      max: 9999,
                      step: _unit == Uom.piece ? 1 : 0.1,
                      decimals: _unit == Uom.piece ? 0 : 2,
                      unit: _unit.symbol,
                      label: 'Quantity',
                      onChanged: (value) => setState(() => _qty = value),
                    ),
                    const Gap.md(),
                    FieldBlock(
                      label: 'Unit',
                      child: DhSegmented<Uom>(
                        value: _unit,
                        dense: true,
                        segments: const [
                          DhSegment(value: Uom.gram, label: 'Grams'),
                          DhSegment(value: Uom.carat, label: 'Carats'),
                          DhSegment(value: Uom.piece, label: 'Pieces'),
                        ],
                        onChanged: (value) => setState(() => _unit = value),
                      ),
                    ),
                    const Gap.md(),
                    MoneyField(
                      value: _unitAmount,
                      label: 'Price per ${_unit.symbol}',
                      onChanged: (value) => setState(() => _unitAmount = value),
                    ),
                    const Gap.md(),
                    DhCard(
                      tone: DhCardTone.inset,
                      child: Row(
                        children: [
                          Expanded(
                            child: DataPair.money(
                              label: 'Line total',
                              amount: _amount,
                              emphasis: DataEmphasis.display,
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                'GST ${GstRates.forCategory(_category.wire)
                                    .toStringAsFixed(0)}%',
                                style: AppTheme.mono(
                                  size: 12,
                                  color: context.scheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: Spacing.xs),
                              Text(
                                'HSN 7113',
                                style: AppTheme.mono(
                                  size: 12,
                                  color: context.scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (!_isNew) ...[
                    const Gap.lg(),
                    TextButton.icon(
                      onPressed: _busy ? null : _delete,
                      style: TextButton.styleFrom(foregroundColor: context.scheme.error),
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: const Text('Remove this line'),
                    ),
                  ],
                ],
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: context.dh.surfaceContainerLowest,
                border: Border(top: BorderSide(color: context.dh.outlineVariant)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (blocked != null) ...[
                      NoteStrip(
                        tone: NoteTone.consequence,
                        icon: Icons.lock_outline_rounded,
                        text: blocked,
                      ),
                      const Gap.sm(),
                    ],
                    FilledButton(
                      onPressed: blocked == null && !_busy ? _save : null,
                      child: _busy
                          ? SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: context.scheme.onPrimary,
                              ),
                            )
                          : Text(_isNew ? 'Add the line' : 'Save the line'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _hintFor(CostCategory category) => switch (category) {
        CostCategory.metal => '18K white gold',
        CostCategory.gemstones => 'Centre diamond, 1.07 ct',
        CostCategory.labor => 'CAD design and wax',
        CostCategory.setting => 'Pavé setting, 42 stones',
        CostCategory.certification => 'IGI certificate',
      };
}
