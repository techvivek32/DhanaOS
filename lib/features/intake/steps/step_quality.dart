/// Step 9 — quality acceptance.
///
/// `quality_acceptance` is the one screen in the corpus whose defaults were actually thought
/// about: five checks on, strict tolerance opt-in. Those defaults ship unchanged. What did not
/// survive is the rest of it — the tolerance figure was baked into a *label* rather than stored,
/// "Other" as a certifying lab had nowhere to type the lab's name, and choosing the customer as
/// the accepting authority offered a workflow that had no screen and no transition behind it.
///
/// What is agreed here is what QC inspects against later. `AcceptanceCriteria.checklistLabels`
/// turns these switches into the inspector's list, so the card at the bottom of this step is not
/// a summary — it is the actual checklist, shown to the person agreeing to it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
import 'package:dhanaos/features/intake/save_queue.dart';
import 'package:dhanaos/features/intake/spec_edits.dart';
import 'package:dhanaos/features/intake/steps/step_shell.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class StepQuality extends ConsumerWidget {
  const StepQuality({super.key, required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.intake(jobKey);
    final job = draft.requireJob;
    final acceptance = draft.acceptance ?? AcceptanceCriteriaEdit.blank(job.id);

    return IntakeStepScaffold(
      draft: draft,
      jobKey: jobKey,
      step: IntakeStep.quality,
      footerNote: 'QC cannot authorise a piece until every box below is ticked on the bench. '
          'Agreeing to a check here is agreeing to inspect it later.',
      children: [
        _Criteria(draft: draft, acceptance: acceptance, controller: controller),
        const Gap.md(),
        _Tolerance(acceptance: acceptance, controller: controller),
        const Gap.md(),
        _Lab(draft: draft, acceptance: acceptance, controller: controller),
        const Gap.md(),
        _Authority(acceptance: acceptance, controller: controller),
        const Gap.md(),
        _Preview(acceptance: acceptance),
      ],
    );
  }
}

// ================================================================= the six checks

final class _Criteria extends StatelessWidget {
  const _Criteria({
    required this.draft,
    required this.acceptance,
    required this.controller,
  });

  final IntakeDraft draft;
  final AcceptanceCriteria acceptance;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    final metal = draft.metalSpec;
    final hasStones = draft.stones.isNotEmpty || draft.melee.isNotEmpty;

    return DhSectionCard(
      title: 'Acceptance criteria',
      subtitle: 'Six checks. Five are on by default because five are always true of a piece we '
          'would put our name on.',
      leading: const Icon(Icons.fact_check_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ToggleRow(
            title: 'Matches the approved CAD',
            blurb: 'The finished piece is compared against the render the customer signed off.',
            icon: Icons.compare_outlined,
            value: acceptance.matchCad,
            onChanged: (value) => runIntake(
              context,
              () => controller.editAcceptance(matchCad: value),
            ),
          ),
          const Divider(),
          ToggleRow(
            title: 'Metal weight and size verified',
            // The mockup's own helper text read "Target: 4.8g Pt950. Allowable variance: ±0.2g."
            // — a requirement citation in all but name, which is what D-009 formalises.
            blurb: metal?.targetWeightG == null
                ? 'Weighed and measured against the spec. No target weight was set on step 5, '
                    'so QC has nothing to weigh against — set one and this check gets teeth.'
                : 'Weighed against ${metal!.weightLabel} and measured against the recorded size.',
            icon: Icons.scale_outlined,
            value: acceptance.sizeWeightConform,
            onChanged: (value) => runIntake(
              context,
              () => controller.editAcceptance(sizeWeightConform: value),
            ),
          ),
          const Divider(),
          ToggleRow(
            title: 'All stones secure',
            blurb: hasStones
                ? 'Every stone tapped and checked under the loupe before the piece leaves.'
                : 'No stones are specified on this job, so this check will pass trivially.',
            icon: Icons.diamond_outlined,
            value: acceptance.stonesSecure,
            enabled: hasStones,
            onChanged: (value) => runIntake(
              context,
              () => controller.editAcceptance(stonesSecure: value),
            ),
          ),
          const Divider(),
          ToggleRow(
            title: 'Symmetry verified',
            blurb: 'Prongs even, shoulders matched, the head sitting square to the shank.',
            icon: Icons.balance_outlined,
            value: acceptance.symmetry,
            onChanged: (value) => runIntake(
              context,
              () => controller.editAcceptance(symmetry: value),
            ),
          ),
          const Divider(),
          ToggleRow(
            title: 'Finish and polish to standard',
            blurb: 'No file marks, no porosity, the finish specified on step 4 throughout.',
            icon: Icons.auto_fix_high_outlined,
            value: acceptance.highPolish,
            onChanged: (value) => runIntake(
              context,
              () => controller.editAcceptance(highPolish: value),
            ),
          ),
          const Divider(),
          ToggleRow(
            title: 'Strict dimensional tolerance',
            blurb: 'Opt in when the piece has to fit something — a setting, a matching band, an '
                'existing chain. The shop default is ± 0.05 mm.',
            icon: Icons.straighten_rounded,
            value: acceptance.strictTolerance,
            onChanged: (value) => runIntake(
              context,
              () => controller.editAcceptance(
                strictTolerance: value,
                // Give the operator a figure to adjust rather than an empty required field.
                toleranceMm: value && acceptance.toleranceMm == null
                    ? const Opt(0.02)
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================= tolerance

final class _Tolerance extends StatelessWidget {
  const _Tolerance({required this.acceptance, required this.controller});

  final AcceptanceCriteria acceptance;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    if (!acceptance.strictTolerance) {
      return const DhSectionCard(
        title: 'Tolerance',
        subtitle: 'Standard shop tolerance applies.',
        leading: Icon(Icons.straighten_rounded),
        child: NoteStrip(
          text: 'QC works to ± 0.05 mm, which is what the bench holds without being asked. Turn '
              'strict tolerance on above if this piece needs tighter than that.',
        ),
      );
    }

    return DhSectionCard(
      title: 'Tolerance',
      subtitle: 'The figure QC measures to, in millimetres.',
      leading: const Icon(Icons.straighten_rounded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StepperField(
            value: acceptance.toleranceMm ?? 0.02,
            min: 0.005,
            max: 0.5,
            step: 0.005,
            decimals: 3,
            unit: 'mm',
            label: 'Allowable deviation',
            helperText: 'Tighter than 0.01 mm is finishing work, not casting — say so in the '
                'notes below so the bench plans for it.',
            trailing: acceptance.toleranceMm == null
                ? const StatusChip(label: 'Required', tone: ChipTone.warning, dense: true)
                : null,
            onChanged: (value) => runIntake(
              context,
              () => controller.editAcceptance(
                toleranceMm: Opt(value),
                delay: SaveDelay.dragging,
              ),
            ),
          ),
          const Gap.md(),
          NoteStrip(
            tone: NoteTone.consequence,
            icon: Icons.rule_outlined,
            text: 'QC will fail the piece outside ± '
                '${acceptance.effectiveToleranceMm.toStringAsFixed(3)} mm. That is a rework '
                'cycle, so agree a figure the bench can actually hold.',
          ),
        ],
      ),
    );
  }
}

// ================================================================= lab

final class _Lab extends StatelessWidget {
  const _Lab({
    required this.draft,
    required this.acceptance,
    required this.controller,
  });

  final IntakeDraft draft;
  final AcceptanceCriteria acceptance;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    return DhSectionCard(
      title: 'Certifying lab',
      subtitle: 'Who grades the finished piece, if anybody does.',
      leading: const Icon(Icons.workspace_premium_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceWrap<CertLab>(
            values: CertLab.values,
            selected: acceptance.certLab,
            labelOf: (value) => value.label,
            onSelected: (value) => runIntake(
              context,
              () => controller.editAcceptance(certLab: value),
            ),
          ),
          // Every "Other" in the mockups was preselected and had no follow-up field, so the
          // specification said "Other" and the certification stage had nowhere to send the piece.
          OtherDetailField(
            visible: acceptance.certLab == CertLab.other,
            value: acceptance.certLabOther,
            label: 'Name the lab',
            hint: 'GJEPC · SGL Labs · Solitaire Gemmological Laboratories',
            onChanged: (value) => runIntake(
              context,
              () => controller.editAcceptance(
                certLabOther: Opt(value),
                delay: SaveDelay.typing,
              ),
            ),
          ),
          const Gap.md(),
          if (acceptance.skipsCertification)
            NoteStrip(
              tone: NoteTone.consequence,
              icon: Icons.skip_next_outlined,
              text: 'No lab means the certification stage is skipped and the '
                  '${draft.certBufferDays == 0 ? 'certification buffer is' : 'certification '
                      'buffer becomes'} zero days — the delivery plan on step 8 shortens to '
                  'match. Choose a lab again and three days come back.',
            )
          else
            NoteStrip(
              text: 'Certification adds ${draft.certBufferDays} days to the plan and a cost '
                  'line to the quote. It is the stage most often underestimated.',
            ),
        ],
      ),
    );
  }
}

// ================================================================= authority

final class _Authority extends StatelessWidget {
  const _Authority({required this.acceptance, required this.controller});

  final AcceptanceCriteria acceptance;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    return DhSectionCard(
      title: 'Who signs it off',
      subtitle: 'The last word on whether the piece is acceptable.',
      leading: const Icon(Icons.verified_user_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableTileGroup<QualityAuthority>(
            values: QualityAuthority.values,
            selected: acceptance.authority,
            dense: true,
            labelOf: (value) => value.label,
            blurbOf: (value) => switch (value) {
              QualityAuthority.customer =>
                'The end customer approves through the portal before QC signs off.',
              QualityAuthority.jeweler =>
                'The retailer we manufacture for accepts on their customer\'s behalf.',
              QualityAuthority.manufacturer =>
                'We accept our own work against the criteria above.',
              QualityAuthority.internalQc =>
                'The QC inspector\'s authorisation is final, with no external sign-off.',
            },
            iconOf: (value) => switch (value) {
              QualityAuthority.customer => Icons.person_outline_rounded,
              QualityAuthority.jeweler => Icons.storefront_outlined,
              QualityAuthority.manufacturer => Icons.factory_outlined,
              QualityAuthority.internalQc => Icons.fact_check_outlined,
            },
            onChanged: (value) => runIntake(
              context,
              () => controller.editAcceptance(authority: value),
            ),
          ),
          if (acceptance.needsCustomerGate) ...[
            const Gap.md(),
            const NoteStrip(
              tone: NoteTone.consequence,
              icon: Icons.hourglass_top_outlined,
              text: 'Customer sign-off inserts a portal approval before QC can authorise '
                  'dispatch. Build the wait into the delivery date — a customer on a different '
                  'continent does not reply the same afternoon.',
            ),
          ],
          const Gap.md(),
          IntakeTextField(
            value: acceptance.customerNotes,
            label: 'Notes for QC',
            maxLines: 4,
            hint: 'Client has seen the reference piece and will compare against it. Inspect the '
                'inside of the shank — the last order came back for a file mark there.',
            onChanged: (value) => runIntake(
              context,
              () => controller.editAcceptance(
                customerNotes: Opt(value),
                delay: SaveDelay.typing,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================= preview

/// The actual inspection list, not a summary of it. Hallmarking is on it because it survives
/// from the rejected mobile tracker's "Final QC & Hallmarking" (D-002) — a real Indian-market
/// requirement that the 14-stage rail has no separate stage for.
final class _Preview extends StatelessWidget {
  const _Preview({required this.acceptance});

  final AcceptanceCriteria acceptance;

  @override
  Widget build(BuildContext context) {
    final items = acceptance.checklistLabels;

    return DhSectionCard(
      title: 'The QC checklist this creates',
      subtitle: '${items.length} items. D-011 rule 3: authorisation only enables at a full list.',
      leading: const Icon(Icons.checklist_rtl_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.check_box_outline_blank_rounded,
                    size: 18,
                    color: context.scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      item,
                      style: context.text.bodyMedium
                          ?.copyWith(color: context.scheme.onSurface),
                    ),
                  ),
                ],
              ),
            ),
          const Gap.sm(),
          Text(
            acceptance.summary,
            style: AppTheme.mono(size: 11.5, color: context.scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
