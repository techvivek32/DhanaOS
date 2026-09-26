/// Step 5 — metal and materials.
///
/// D-012 makes this step the UNION of `metal_materials` and `quick_specs`. Those two screens were
/// never iterations of one another: one carried base metal, purity, colour, target weight and
/// hallmark; the other carried the five REQ-coded fields — gemstone inset, target budget and
/// delivery target — and neither held the other's. Shipping either alone loses half the
/// specification, so both are here, with the REQ citations D-009 makes first-class.
///
/// Two rules the mockups implied and never enforced:
///
///  * **Purity depends on the base metal.** `metal_materials` offered a flat purity list, so 22K
///    rose gold was selectable — and that is not a product. `BaseMetal.purities` is the
///    dependency; here the chips a metal cannot take are disabled and say why.
///  * **REQ-GEM-03 answered No skips the stone step.** The mockup's call to action read
///    PROCEED TO STONES whichever way the question was answered.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
import 'package:dhanaos/features/intake/save_queue.dart';
import 'package:dhanaos/features/intake/spec_edits.dart';
import 'package:dhanaos/features/intake/steps/step_shell.dart';
import 'package:dhanaos/features/intake/widgets/date_field.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class StepMetal extends ConsumerWidget {
  const StepMetal({super.key, required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.intake(jobKey);
    final job = draft.requireJob;
    final metal = draft.metalSpec ?? MetalSpecEdit.blank(job.id);

    return IntakeStepScaffold(
      draft: draft,
      jobKey: jobKey,
      step: IntakeStep.metal,
      footerNote: 'The target weight is what casting is charged against and what QC weighs the '
          'finished piece to. Set it here and nobody has to guess at the bench.',
      children: [
        _Alloy(metal: metal, controller: controller),
        const Gap.md(),
        _Weight(metal: metal, controller: controller),
        const Gap.md(),
        _Marking(metal: metal, controller: controller),
        const Gap.md(),
        _GemstoneInset(metal: metal, controller: controller),
        const Gap.md(),
        _Budget(draft: draft, metal: metal, controller: controller),
        const Gap.md(),
        _DeliveryTarget(draft: draft, controller: controller),
        const Gap.md(),
        _Summary(draft: draft, metal: metal),
      ],
    );
  }
}

// ================================================================= alloy

final class _Alloy extends StatelessWidget {
  const _Alloy({required this.metal, required this.controller});

  final MetalSpec metal;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    final base = metal.baseMetal;
    final allowed = base?.purities ?? const <MetalPurity>[];

    return DhSectionCard(
      title: 'Alloy',
      subtitle: 'What the piece is cast in. Everything downstream is priced off this.',
      leading: const Icon(Icons.layers_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FieldBlock(
            label: 'Base metal',
            reqCode: 'REQ-MAT-01',
            reqCritical: true,
            child: ChoiceWrap<BaseMetal>(
              values: BaseMetal.values,
              selected: base,
              labelOf: (value) => value.label,
              onSelected: (value) => runIntake(
                context,
                () => controller.editMetalSpec(baseMetal: Opt(value)),
              ),
            ),
          ),
          const Gap.md(),
          FieldBlock(
            label: 'Alloy purity',
            reqCode: 'REQ-PUR-02',
            reqCritical: true,
            helper: base == null
                ? 'Purity depends on the metal, so choose the metal first.'
                : '${base.label} is made in '
                    '${[for (final p in allowed) p.label].join(', ')}.',
            child: ChoiceWrap<MetalPurity>(
              values: MetalPurity.values,
              selected: metal.purity,
              mono: true,
              labelOf: (value) => value.label,
              // The dependency the mockups declared and never enforced: a purity a metal is not
              // made in is not offered, and says so rather than going quietly grey.
              enabledOf: (value) => base != null && allowed.contains(value),
              disabledReasonOf: (value) => base == null
                  ? 'Choose the base metal first — purity depends on it.'
                  : '${value.label} is not a ${base.label.toLowerCase()} purity.',
              onSelected: (value) => runIntake(
                context,
                () => controller.editMetalSpec(purity: Opt(value)),
              ),
            ),
          ),
          if (base != null && base.hasColor) ...[
            const Gap.md(),
            FieldBlock(
              label: 'Colour',
              helper: 'Colour is an alloy choice, so it only exists for gold. '
                  'Two-tone needs the split described in the alloy notes below.',
              child: ChoiceWrap<MetalColor>(
                values: MetalColor.values,
                selected: metal.color,
                labelOf: (value) => value.label,
                onSelected: (value) => runIntake(
                  context,
                  () => controller.editMetalSpec(color: Opt(value)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= weight

final class _Weight extends StatelessWidget {
  const _Weight({required this.metal, required this.controller});

  final MetalSpec metal;
  final IntakeController controller;

  /// A solitaire in 18K sits near this, and it is the figure an operator adjusts from rather
  /// than types. Nothing is written until the stepper is touched.
  static const _defaultTargetG = 5.0;
  static const _defaultToleranceG = 0.3;

  @override
  Widget build(BuildContext context) {
    final target = metal.targetWeightG;
    final tolerance = metal.weightTolG;

    return DhSectionCard(
      title: 'Target weight',
      subtitle: 'The binding figure. Casting quotes against it and QC weighs to it.',
      leading: const Icon(Icons.scale_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StepperField(
            value: target ?? _defaultTargetG,
            min: 0.1,
            max: 500,
            step: 0.1,
            decimals: 2,
            unit: 'g',
            label: 'Finished metal weight',
            helperText: 'Metal only, stones excluded. A comfort-fit band runs heavier than a '
                'standard one at the same finger size.',
            trailing: target == null
                ? const StatusChip(label: 'Not set', dense: true)
                : null,
            onChanged: (value) => runIntake(
              context,
              () => controller.editMetalSpec(
                targetWeightG: Opt(value),
                delay: SaveDelay.dragging,
              ),
            ),
          ),
          const Gap.md(),
          StepperField(
            value: tolerance ?? _defaultToleranceG,
            min: 0,
            max: 5,
            step: 0.05,
            decimals: 2,
            unit: 'g',
            label: 'Allowable variance',
            helperText: 'QC passes the piece inside this band. Leave it at zero and any '
                'deviation at all is a QC failure.',
            trailing: tolerance == null
                ? const StatusChip(label: 'Not set', dense: true)
                : null,
            onChanged: (value) => runIntake(
              context,
              () => controller.editMetalSpec(
                weightTolG: Opt(value),
                delay: SaveDelay.dragging,
              ),
            ),
          ),
          const Gap.md(),
          ToggleRow(
            title: 'Client is supplying the metal',
            blurb: 'Scrap, old jewellery or raw bullion coming in from the customer. '
                'It is weighed in at goods-in and does not go on the invoice as a charge.',
            icon: Icons.inventory_2_outlined,
            value: metal.customerSupplied,
            onChanged: (value) => runIntake(
              context,
              () => controller.editMetalSpec(customerSupplied: value),
            ),
          ),
          if (metal.customerSupplied) ...[
            const Gap.sm(),
            const NoteStrip(
              tone: NoteTone.consequence,
              icon: Icons.shield_outlined,
              text: 'Client metal is in our care from the moment it is weighed in. Put the '
                  'declared weight and the receipt number on the cost line for it on the '
                  'pricing step, and mark that line client-supplied so it carries a declared '
                  'value instead of a price.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= hallmark and notes

final class _Marking extends StatelessWidget {
  const _Marking({required this.metal, required this.controller});

  final MetalSpec metal;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    return DhSectionCard(
      title: 'Marking and alloy notes',
      subtitle: 'What is stamped inside, and anything the caster has to know.',
      leading: const Icon(Icons.local_offer_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IntakeTextField(
            value: metal.hallmark,
            label: 'Hallmark',
            // Kept from the rejected mobile tracker's "Final QC & Hallmarking" (D-002): BIS
            // hallmarking is a real Indian-market requirement, not a nice-to-have.
            helper: 'Stamped inside the shank. BIS hallmarking applies to the Indian market.',
            hint: '18K · AF · BIS 916',
            mono: true,
            textCapitalization: TextCapitalization.characters,
            onChanged: (value) => runIntake(
              context,
              () => controller.editMetalSpec(
                hallmark: Opt(value),
                delay: SaveDelay.typing,
              ),
            ),
          ),
          const Gap.md(),
          IntakeTextField(
            value: metal.alloyNotes,
            label: 'Alloy notes',
            maxLines: 4,
            hint: 'Yellow shank with a white-gold head. Nickel-free alloy — client reacts to '
                'nickel. Match the previous order\'s colour exactly.',
            onChanged: (value) => runIntake(
              context,
              () => controller.editMetalSpec(
                alloyNotes: Opt(value),
                delay: SaveDelay.typing,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================= REQ-GEM-03

final class _GemstoneInset extends StatelessWidget {
  const _GemstoneInset({required this.metal, required this.controller});

  final MetalSpec metal;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    final answered = metal.gemstoneInset;

    return DhSectionCard(
      title: 'Stones',
      subtitle: 'This answer decides whether the next step asks about stones at all.',
      leading: const Icon(Icons.brightness_high_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FieldBlock(
            label: 'Is the piece set with stones?',
            reqCode: 'REQ-GEM-03',
            reqCritical: true,
            child: DhSegmented<bool>(
              value: answered,
              segments: const [
                DhSegment(value: true, label: 'Yes', icon: Icons.diamond_outlined),
                DhSegment(value: false, label: 'No', icon: Icons.block_outlined),
              ],
              onChanged: (value) => runIntake(
                context,
                () => controller.editMetalSpec(gemstoneInset: Opt(value)),
              ),
            ),
          ),
          const Gap.sm(),
          if (answered == null)
            const NoteStrip(
              text: 'Unanswered. The wizard will still walk you through the stone step, but the '
                  'job order will not say whether a plain band was intended or a stone was '
                  'forgotten.',
            )
          else if (answered == false)
            const NoteStrip(
              tone: NoteTone.consequence,
              icon: Icons.skip_next_outlined,
              text: 'Step 6 is skipped. Answer Yes again at any time and it comes back — nothing '
                  'already captured about stones is thrown away.',
            )
          else
            const NoteStrip(
              tone: NoteTone.good,
              icon: Icons.check_circle_outline_rounded,
              text: 'The next step takes the centre stone, any side stones, and melee by the '
                  'parcel. Origin — natural or lab grown — is asked for every one of them.',
            ),
        ],
      ),
    );
  }
}

// ================================================================= REQ-FIN-04

final class _Budget extends StatelessWidget {
  const _Budget({required this.draft, required this.metal, required this.controller});

  final IntakeDraft draft;
  final MetalSpec metal;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    final currency = draft.currency;
    final low = metal.targetBudgetMin(currency);
    final high = metal.targetBudgetMax(currency);
    final inverted = low != null && high != null && !high.isZero && high.minor < low.minor;

    return DhSectionCard(
      title: 'Target budget',
      subtitle: 'The band the customer gave. The pricing step measures the quote against it.',
      leading: const Icon(Icons.savings_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FieldBlock(
            label: 'Budget band',
            reqCode: 'REQ-FIN-04',
            // D-004: never a literal symbol. The field reads the job's own currency, which is
            // what makes a US retailer's job quotable in dollars against an INR workshop.
            helper: 'In ${currency == 'INR' ? 'rupees' : currency}. Leave a side blank if the '
                'customer only gave one figure.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MoneyField(
                  value: low ?? draft.zero,
                  label: 'From',
                  onChanged: (value) => runIntake(
                    context,
                    () => controller.editMetalSpec(
                      targetBudgetMin: value.isZero
                          ? const Opt<Money>.clear()
                          : Opt(value),
                      delay: SaveDelay.typing,
                    ),
                  ),
                ),
                const Gap.md(),
                MoneyField(
                  value: high ?? draft.zero,
                  label: 'Up to',
                  errorText: inverted
                      ? 'The upper figure is below the lower one.'
                      : null,
                  onChanged: (value) => runIntake(
                    context,
                    () => controller.editMetalSpec(
                      targetBudgetMax: value.isZero
                          ? const Opt<Money>.clear()
                          : Opt(value),
                      delay: SaveDelay.typing,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (high != null && !high.isZero) ...[
            const Gap.sm(),
            NoteStrip(
              text: 'The pricing step draws a bar against ${high.format(compact: true)} and '
                  'turns it red if the quote goes past it. Nothing is blocked by it — an '
                  'over-budget quote is a conversation, not an error.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= REQ-TML-05

/// The delivery date belongs to step 8, which plans the whole rail backwards from it. It appears
/// here because `quick_specs` carried REQ-TML-05 alongside the budget, and the customer says both
/// numbers in the same breath. It is the same column — `delivery_schedules.requested_date` — so
/// typing it here and refining it on step 8 cannot produce two answers.
final class _DeliveryTarget extends StatelessWidget {
  const _DeliveryTarget({required this.draft, required this.controller});

  final IntakeDraft draft;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    final requested = draft.delivery?.requestedDate ?? draft.job?.requestedDelivery;

    return DhSectionCard(
      title: 'Delivery target',
      subtitle: 'Roughly when the customer needs it. Step 8 plans the rail backwards from it.',
      leading: const Icon(Icons.event_available_outlined),
      child: FieldBlock(
        label: 'Requested date',
        reqCode: 'REQ-TML-05',
        helper: 'At this priority the job needs ${draft.leadDays} days end to end, so the '
            'earliest honest date today is '
            '${_dayLabel(draft.earliestDelivery)}.',
        child: DateField(
          value: requested,
          firstDate: IntakeDraft.today,
          lastDate: IntakeDraft.today.add(const Duration(days: 730)),
          helpText: 'When does the customer need it?',
          emptyLabel: 'No date agreed yet',
          warning: draft.deliveryBeatsLeadTime
              ? 'That is sooner than ${draft.leadDays} days from today. Step 8 will ask you to '
                  'move it or raise the priority.'
              : null,
          onChanged: (value) => runIntake(
            context,
            () => controller.editDelivery(requestedDate: Opt(value)),
          ),
          onCleared: () => runIntake(
            context,
            () => controller.editDelivery(requestedDate: const Opt<DateTime>.clear()),
          ),
        ),
      ),
    );
  }

  static String _dayLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}

// ================================================================= summary

/// What the caster will read off the job bag. Rendering it back means an operator sees the
/// specification the way the shop floor will, before leaving the step.
final class _Summary extends StatelessWidget {
  const _Summary({required this.draft, required this.metal});

  final IntakeDraft draft;
  final MetalSpec metal;

  @override
  Widget build(BuildContext context) {
    return DhSectionCard(
      title: 'On the job bag',
      leading: const Icon(Icons.receipt_long_outlined),
      child: DataPairGrid(
        children: [
          DataPair.mono(
            label: 'Alloy',
            value: metal.alloyLabel,
            emphasis: DataEmphasis.strong,
            valueColor: metal.purityIsValid ? null : context.scheme.error,
          ),
          DataPair.mono(
            label: 'Weight',
            value: metal.weightLabel,
            emphasis: DataEmphasis.strong,
          ),
          DataPair.mono(
            label: 'Budget',
            value: metal.budgetLabel(draft.currency),
          ),
          DataPair.mono(
            label: 'Hallmark',
            value: metal.hallmark?.trim().isNotEmpty == true
                ? metal.hallmark!.trim()
                : DataPair.placeholder,
          ),
          DataPair.custom(
            label: 'Stones',
            child: StatusChip(
              label: switch (metal.gemstoneInset) {
                null => 'Not answered',
                true => 'Set with stones',
                false => 'Plain metal',
              },
              tone: switch (metal.gemstoneInset) {
                null => ChipTone.warning,
                true => ChipTone.accent,
                false => ChipTone.neutral,
              },
              dense: true,
            ),
          ),
          DataPair.custom(
            label: 'Metal supplied by',
            child: StatusChip(
              label: metal.customerSupplied ? 'Client' : 'Workshop',
              tone: metal.customerSupplied ? ChipTone.warning : ChipTone.neutral,
              dense: true,
            ),
          ),
        ],
      ),
    );
  }
}
