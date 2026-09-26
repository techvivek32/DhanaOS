/// Step 7 — pricing.
///
/// D-012 calls `commercial_requirements` the least-evolved step in the corpus, and it is: the
/// screen had **no inputs at all**. Three pricing-basis buttons with no JavaScript behind them,
/// four hardcoded charges summing to $970 that no screen ever displayed, and a utilisation bar
/// written as `style="width: 85%"` when the real figure was 90.8%. So this step is mostly
/// net-new, built on three decisions:
///
///  * **D-003** — five customer-facing categories. The mockup's four internal lines (CAD Design,
///    Setting, Finishing & Polish, Certification) fold into them; CAD and finishing are `labor`.
///  * **D-004** — money is integer minor units plus a currency, and an Indian manufacturer cannot
///    ship without a tax invoice, so the GST split is previewed here rather than discovered at
///    invoicing time.
///  * **`PricingBasis`** — Cost Plus reveals a margin field, Quote introduces an approval state.
///    Neither branch existed.
///
/// Every figure on this screen is computed. Nothing is a painted percentage.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
import 'package:dhanaos/features/intake/steps/step_shell.dart';
import 'package:dhanaos/features/intake/widgets/cost_line_sheet.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class StepCommercials extends ConsumerWidget {
  const StepCommercials({super.key, required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.intake(jobKey);
    final quote = draft.quote;

    if (quote == null) {
      // The draft quote is created on entry to this step. Until it lands there is nothing for a
      // cost line to attach to, so the screen says so rather than drawing an empty breakdown.
      return IntakeStepScaffold(
        draft: draft,
        jobKey: jobKey,
        step: IntakeStep.commercials,
        children: [
          DhCard(
            child: EmptyState(
              icon: Icons.request_quote_outlined,
              title: 'The draft quote has not opened yet',
              message: 'Every cost line hangs off a quote. Retry and one is created for this '
                  'job, or go back a step and come forward again.',
              actionLabel: 'Open the quote',
              onAction: () => runIntake(context, controller.ensureQuote),
              compact: true,
            ),
          ),
        ],
      );
    }

    return IntakeStepScaffold(
      draft: draft,
      jobKey: jobKey,
      step: IntakeStep.commercials,
      footerNote: 'The customer approves this breakdown line by line. Anything vague here comes '
          'back as a question later.',
      children: [
        _Basis(quote: quote, controller: controller),
        const Gap.md(),
        _Envelope(draft: draft),
        const Gap.md(),
        _Breakdown(draft: draft, quote: quote, controller: controller),
        const Gap.md(),
        _Targets(draft: draft, quote: quote, controller: controller),
        const Gap.md(),
        _Gst(draft: draft),
      ],
    );
  }
}

// ================================================================= basis

final class _Basis extends StatelessWidget {
  const _Basis({required this.quote, required this.controller});

  final Quote quote;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    return DhSectionCard(
      title: 'Pricing basis',
      subtitle: 'How the number is arrived at, which decides what the customer is shown.',
      leading: const Icon(Icons.calculate_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableTileGroup<PricingBasis>(
            values: PricingBasis.values,
            selected: quote.basis,
            dense: true,
            labelOf: (value) => value.label,
            blurbOf: (value) => switch (value) {
              PricingBasis.fixed =>
                'One agreed price. Cost movement is the workshop\'s risk, not the customer\'s.',
              PricingBasis.quote =>
                'The customer approves the breakdown before work starts.',
              PricingBasis.costPlus =>
                'Cost is passed through with an agreed margin on top.',
            },
            iconOf: (value) => switch (value) {
              PricingBasis.fixed => Icons.lock_outline_rounded,
              PricingBasis.quote => Icons.how_to_reg_outlined,
              PricingBasis.costPlus => Icons.percent_rounded,
            },
            onChanged: (value) => runIntake(
              context,
              () => controller.setQuoteTerms(basis: value),
            ),
          ),
          // Cost Plus must reveal a margin field. The mockup's three buttons had no behaviour at
          // all, so this branch has never existed before.
          if (quote.basis.needsMargin) ...[
            const Gap.md(),
            _MarginField(quote: quote, controller: controller),
          ],
          if (quote.basis.needsApproval) ...[
            const Gap.md(),
            const NoteStrip(
              tone: NoteTone.consequence,
              icon: Icons.how_to_reg_outlined,
              text: 'On a Quote basis the customer sees this breakdown and approves it before '
                  'the bench starts. The Cost Analysis gate on the review step is what sends it.',
            ),
          ],
        ],
      ),
    );
  }
}

final class _MarginField extends StatefulWidget {
  const _MarginField({required this.quote, required this.controller});

  final Quote quote;
  final IntakeController controller;

  @override
  State<_MarginField> createState() => _MarginFieldState();
}

class _MarginFieldState extends State<_MarginField> {
  late double _margin = widget.quote.marginPct ?? 25;

  @override
  void didUpdateWidget(_MarginField old) {
    super.didUpdateWidget(old);
    final incoming = widget.quote.marginPct;
    if (incoming != null && incoming != _margin) _margin = incoming;
  }

  @override
  Widget build(BuildContext context) {
    final quote = widget.quote;
    final uplift = quote.subtotal.percent(_margin);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StepperField(
          value: _margin,
          min: 0,
          max: 200,
          step: 0.5,
          decimals: 1,
          unit: '%',
          label: 'Margin on cost',
          helperText: quote.marginPct == null
              ? 'Cost Plus without a margin is not a price. This step will not pass until it '
                  'is set.'
              : 'Adds ${uplift.format()} to the ${quote.subtotal.format()} of cost below.',
          trailing: quote.marginPct == null
              ? const StatusChip(label: 'Required', tone: ChipTone.warning, dense: true)
              : null,
          onChanged: (value) {
            setState(() => _margin = value);
            runIntake(context, () => widget.controller.setQuoteTerms(marginPct: value));
          },
        ),
      ],
    );
  }
}

// ================================================================= envelope

/// The computed envelope. The mockup drew `style="width: 85%"` beside a figure that was actually
/// 90.8% — a bar that cannot be wrong is a bar nobody should trust, so this one is derived from
/// the totals every time it paints.
final class _Envelope extends StatelessWidget {
  const _Envelope({required this.draft});

  final IntakeDraft draft;

  @override
  Widget build(BuildContext context) {
    final ceiling = draft.costCeiling;
    final target = draft.costTarget;
    final total = draft.quoteTotal;
    final used = draft.envelopeUsed;
    final over = draft.isOverEnvelope;

    return DhSectionCard(
      title: 'Against the envelope',
      subtitle: ceiling == null
          ? 'No ceiling set. Give a maximum below and this measures the quote against it.'
          : 'Grand total against the approved maximum.',
      leading: const Icon(Icons.speed_outlined),
      accent: over ? context.scheme.error : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: DataPair.money(
                  label: 'Grand total',
                  amount: total,
                  emphasis: DataEmphasis.display,
                  valueColor: over ? context.scheme.error : null,
                ),
              ),
              if (used != null)
                Text(
                  // One decimal, because the gap between 85 and 90.8 is the whole point.
                  '${(used * 100).toStringAsFixed(1)}%',
                  style: AppTheme.mono(
                    size: 20,
                    weight: FontWeight.w700,
                    color: over ? context.scheme.error : context.dh.goldText,
                  ),
                ),
            ],
          ),
          const Gap.md(),
          if (used == null)
            const NoteStrip(
              text: 'Nothing to measure against yet. A bar with no ceiling always reads "fine", '
                  'so none is drawn.',
            )
          else
            _EnvelopeBar(
              used: used,
              targetFraction: (target == null || ceiling == null || ceiling.isZero)
                  ? null
                  : target.minor / ceiling.minor,
              over: over,
            ),
          const Gap.md(),
          DataPairGrid(
            children: [
              DataPair.money(label: 'Cost subtotal', amount: draft.quoteSubtotal),
              DataPair.money(label: 'Tax', amount: draft.quoteTax),
              if (target != null) DataPair.money(label: 'Target price', amount: target),
              if (ceiling != null)
                DataPair.money(
                  label: 'Ceiling',
                  amount: ceiling,
                  valueColor: over ? context.scheme.error : null,
                ),
            ],
          ),
          if (over) ...[
            const Gap.md(),
            NoteStrip(
              tone: NoteTone.risk,
              icon: Icons.trending_up_rounded,
              text: 'The quote is ${(total - ceiling!).format()} over the ceiling. Nothing is '
                  'blocked — an over-budget quote is a conversation with the customer, not an '
                  'error. It will show on the review step so nobody is surprised by it.',
            ),
          ],
        ],
      ),
    );
  }
}

final class _EnvelopeBar extends StatelessWidget {
  const _EnvelopeBar({required this.used, required this.targetFraction, required this.over});

  final double used;
  final double? targetFraction;
  final bool over;

  @override
  Widget build(BuildContext context) {
    final dh = context.dh;
    final fill = over ? context.scheme.error : dh.gold;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final marker = targetFraction;
        return SizedBox(
          height: 26,
          child: Stack(
            children: [
              Positioned.fill(
                top: 7,
                bottom: 7,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: dh.surfaceContainerHigh,
                    borderRadius: Radii.rFull,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 7,
                bottom: 7,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: used.clamp(0.0, 1.0)),
                  duration: context.motion(Motion.normal),
                  curve: context.motionCurve,
                  builder: (context, t, _) => Container(
                    width: width * t,
                    decoration: BoxDecoration(color: fill, borderRadius: Radii.rFull),
                  ),
                ),
              ),
              if (marker != null && marker > 0 && marker <= 1)
                Positioned(
                  left: (width * marker).clamp(0.0, width - 2),
                  top: 0,
                  bottom: 0,
                  child: Tooltip(
                    message: 'Target price',
                    child: Container(width: 2, color: context.scheme.onSurface),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================= breakdown

final class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.draft, required this.quote, required this.controller});

  final IntakeDraft draft;
  final Quote quote;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    final byCategory = quote.byCategory;
    final clientLines = [for (final l in quote.lines) if (l.isClientOwned) l];

    return DhSectionCard(
      title: 'Cost breakdown',
      subtitle: '${quote.lines.length} line${quote.lines.length == 1 ? '' : 's'} across the '
          'five categories the customer approves.',
      leading: const Icon(Icons.receipt_long_outlined),
      action: IconButton(
        tooltip: 'Add a cost line',
        icon: const Icon(Icons.add_rounded),
        onPressed: () => showCostLineSheet(
          context,
          controller: controller,
          currency: draft.currency,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (quote.lines.isEmpty)
            EmptyState(
              icon: Icons.playlist_add_outlined,
              title: 'No charges yet',
              message: 'Start with the metal — weight times today\'s rate — then the stones, '
                  'the labour and the certificate.',
              actionLabel: 'Add the first line',
              onAction: () => showCostLineSheet(
                context,
                controller: controller,
                currency: draft.currency,
              ),
              compact: true,
            )
          else
            for (final category in CostCategory.values) ...[
              _CategoryBlock(
                category: category,
                total: byCategory[category] ?? draft.zero,
                lines: [
                  for (final l in quote.lines)
                    if (l.category == category && !l.isClientOwned) l,
                ],
                draft: draft,
                controller: controller,
              ),
            ],
          if (clientLines.isNotEmpty) ...[
            const Gap.md(),
            Divider(height: 1, thickness: 1, color: context.dh.outlineVariant),
            const Gap.md(),
            Text(
              'CLIENT-SUPPLIED MATERIAL · NOT CHARGED',
              style: context.text.labelSmall?.copyWith(color: context.dh.goldText),
            ),
            const Gap.sm(),
            for (final line in clientLines)
              _LineRow(
                line: line,
                draft: draft,
                controller: controller,
                clientOwned: true,
              ),
          ],
          const Gap.md(),
          Divider(height: 1, thickness: 1, color: context.dh.outlineVariant),
          const Gap.md(),
          _TotalRow(label: 'Subtotal', amount: draft.quoteSubtotal),
          const Gap.sm(),
          _TotalRow(label: 'Tax', amount: draft.quoteTax),
          const Gap.sm(),
          _TotalRow(label: 'Grand total', amount: draft.quoteTotal, strong: true),
          if (!quote.totalsAgree) ...[
            const Gap.md(),
            const NoteStrip(
              tone: NoteTone.consequence,
              icon: Icons.sync_problem_outlined,
              text: 'The lines on screen and the server\'s subtotal disagree. Leaving and '
                  're-entering this step re-reads the figures Postgres computed, which are the '
                  'ones the invoice will use.',
            ),
          ],
        ],
      ),
    );
  }
}

final class _CategoryBlock extends StatelessWidget {
  const _CategoryBlock({
    required this.category,
    required this.total,
    required this.lines,
    required this.draft,
    required this.controller,
  });

  final CostCategory category;
  final Money total;
  final List<CostLine> lines;
  final IntakeDraft draft;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  category.label.toUpperCase(),
                  style: context.text.labelSmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
              ),
              Text(
                total.format(),
                style: AppTheme.mono(
                  size: 13,
                  weight: FontWeight.w600,
                  color: total.isZero
                      ? context.scheme.onSurfaceVariant
                      : context.scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          if (lines.isEmpty)
            InkWell(
              borderRadius: Radii.rMd,
              onTap: () => showCostLineSheet(
                context,
                controller: controller,
                currency: draft.currency,
                category: category,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
                child: Row(
                  children: [
                    Icon(Icons.add_rounded, size: 16, color: context.scheme.onSurfaceVariant),
                    const SizedBox(width: Spacing.sm),
                    Text(
                      'Add a ${category.label.toLowerCase()} charge',
                      style: context.text.bodySmall
                          ?.copyWith(color: context.scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          else
            for (final line in lines)
              _LineRow(line: line, draft: draft, controller: controller),
        ],
      ),
    );
  }
}

final class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.draft,
    required this.controller,
    this.clientOwned = false,
  });

  final CostLine line;
  final IntakeDraft draft;
  final IntakeController controller;
  final bool clientOwned;

  @override
  Widget build(BuildContext context) {
    final amount = clientOwned
        ? (line.declaredValueIn(draft.currency) ?? draft.zero)
        : line.amountIn(draft.currency);

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: InkWell(
        borderRadius: Radii.rMd,
        onTap: () => showCostLineSheet(
          context,
          controller: controller,
          currency: draft.currency,
          line: line,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line.label,
                      style: context.text.bodyMedium
                          ?.copyWith(color: context.scheme.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      line.detailLabel,
                      style: AppTheme.mono(
                        size: 11.5,
                        color: context.scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    amount.format(),
                    style: AppTheme.mono(
                      size: 13.5,
                      weight: FontWeight.w600,
                      color: clientOwned
                          ? context.dh.goldText
                          : context.scheme.onSurface,
                    ),
                  ),
                  if (clientOwned)
                    Text(
                      'declared',
                      style: AppTheme.mono(size: 10, color: context.dh.goldText),
                    ),
                ],
              ),
              const SizedBox(width: Spacing.xs),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: context.scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _TotalRow extends StatelessWidget {
  const _TotalRow({required this.label, required this.amount, this.strong = false});

  final String label;
  final Money amount;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label.toUpperCase(),
            style: context.text.labelSmall?.copyWith(
              color: strong ? context.scheme.onSurface : context.scheme.onSurfaceVariant,
            ),
          ),
        ),
        Text(
          amount.format(),
          style: AppTheme.mono(
            size: strong ? 18 : 13.5,
            weight: strong ? FontWeight.w700 : FontWeight.w500,
            color: strong ? context.scheme.onSurface : context.scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ================================================================= targets

final class _Targets extends StatelessWidget {
  const _Targets({required this.draft, required this.quote, required this.controller});

  final IntakeDraft draft;
  final Quote quote;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    return DhSectionCard(
      title: 'Target and ceiling',
      subtitle: 'What the job is aimed at, and what it may not exceed without a conversation.',
      leading: const Icon(Icons.flag_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MoneyField(
            value: quote.targetUnitPrice ?? draft.zero,
            label: 'Target unit price',
            helperText: 'The figure the job was sold at, per piece.',
            onChanged: (value) => runIntake(
              context,
              () => controller.setQuoteTerms(targetUnitPrice: value),
            ),
          ),
          const Gap.md(),
          MoneyField(
            value: quote.maxApproved ?? draft.zero,
            label: 'Maximum approved',
            helperText: 'The ceiling the bar above is drawn against. Defaults to the budget '
                'band captured on the metal step when left blank.',
            onChanged: (value) => runIntake(
              context,
              () => controller.setQuoteTerms(maxApproved: value),
            ),
          ),
          if (draft.job?.quantity != null && draft.job!.quantity > 1) ...[
            const Gap.md(),
            NoteStrip(
              text: 'This job is for ${draft.job!.quantity} pieces. The target above is per '
                  'piece; the breakdown is for the whole order.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= GST

/// D-004. An Indian manufacturer cannot legally ship without a tax invoice, and jewellery is not
/// one rate: HSN 7113 is 3%, making charges are 5%, certification is a service at 18%. Interstate
/// supply is IGST; intrastate splits into CGST + SGST, decided by comparing the first two digits
/// of the customer's GSTIN with the workshop's.
final class _Gst extends StatelessWidget {
  const _Gst({required this.draft});

  final IntakeDraft draft;

  @override
  Widget build(BuildContext context) {
    final gst = draft.gst;
    final customer = draft.customer;

    return DhSectionCard(
      title: 'Tax preview',
      subtitle: gst == null
          ? 'Add a cost line and the GST split appears here.'
          : gst.headingLabel,
      leading: const Icon(Icons.account_balance_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (gst == null)
            const NoteStrip(
              text: 'Nothing taxable yet. Client-supplied material never appears here — it is '
                  'held, not sold.',
            )
          else ...[
            DataPairGrid(
              children: [
                DataPair.money(label: 'Taxable value', amount: gst.taxable),
                if (gst.interstate)
                  DataPair.money(label: 'IGST', amount: gst.igst)
                else ...[
                  DataPair.money(label: 'CGST', amount: gst.cgst),
                  DataPair.money(label: 'SGST', amount: gst.sgst),
                ],
                DataPair.money(
                  label: 'Invoice total',
                  amount: gst.total,
                  emphasis: DataEmphasis.strong,
                ),
              ],
            ),
            if (gst.byRate.length > 1) ...[
              const Gap.md(),
              Text(
                'BY RATE',
                style: context.text.labelSmall
                    ?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
              const Gap.sm(),
              for (final entry in gst.byRate.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${entry.key.toStringAsFixed(0)}%',
                          style: AppTheme.mono(
                            size: 12.5,
                            color: context.scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Text(
                        entry.value.format(),
                        style: AppTheme.mono(
                          size: 12.5,
                          color: context.scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
          const Gap.md(),
          if (customer == null)
            const NoteStrip(
              tone: NoteTone.consequence,
              text: 'No customer on the job yet, so place of supply is unknown and the preview '
                  'assumes interstate. Set the customer on step 2 to get the real split.',
            )
          else if (!customer.isGstRegistered)
            NoteStrip(
              tone: NoteTone.consequence,
              text: '${customer.name} has no GSTIN on file. Place of supply cannot be decided '
                  'without one, so this falls back to IGST — the conservative choice, because '
                  'under-collecting is the costlier error.',
            )
          else if (draft.org?.canRaiseTaxInvoice != true)
            const NoteStrip(
              tone: NoteTone.risk,
              icon: Icons.gavel_outlined,
              text: 'The workshop has no GSTIN recorded. A tax invoice cannot legally be raised '
                  'without one — the quote is fine, the invoice will not be.',
            ),
        ],
      ),
    );
  }
}
