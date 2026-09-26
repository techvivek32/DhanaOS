/// Step 4 — the design specification.
///
/// D-012 takes `engagement_ring_specs_expanded` as the base: it is `visual_design_specs` plus
/// metal finish, band profile and side-stone setting. Two things are fixed rather than ported:
///
///  * **Every "Other" gets a follow-up field.** In the mockups each `Other` was preselected and
///    had nothing behind it, so the spec read "Setting: Other" and the bench had to telephone.
///  * **The dimensions are conditional.** The mockups hardcoded ring size and band width onto
///    every product. `ProductCategory` carries `usesRingSize` / `usesInnerDiameter` / `usesLength`
///    / `usesDrop` for exactly this, and the fields swap on it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import 'package:dhanaos/features/intake/widgets/ring_size_field.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class StepDesign extends ConsumerWidget {
  const StepDesign({super.key, required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.intake(jobKey);
    final job = draft.requireJob;
    final spec = draft.productSpec ?? ProductSpecEdit.blank(job.id);
    final category = draft.category ?? ProductCategory.other;

    return IntakeStepScaffold(
      draft: draft,
      jobKey: jobKey,
      step: IntakeStep.design,
      footerNote: 'The CAD designer builds from this. Anything left blank becomes a phone call.',
      children: [
        DhSectionCard(
          title: 'How it is built',
          leading: const Icon(Icons.architecture_outlined),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FieldBlock(
                label: 'Setting style',
                helper: 'How the centre stone is held.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ChoiceWrap<SettingStyle>(
                      values: SettingStyle.values,
                      selected: spec.settingStyle,
                      labelOf: (value) => value.label,
                      onSelected: (value) =>
                          controller.editProductSpec(settingStyle: Opt(value)),
                    ),
                    OtherDetailField(
                      visible: spec.settingStyle?.needsDetail ?? false,
                      value: spec.settingDetail,
                      label: 'Describe the setting',
                      hint: '6-Prong Cathedral, Micro-pavé shoulders',
                      onChanged: (value) => controller.editProductSpec(
                        settingDetail: Opt(value),
                        delay: SaveDelay.typing,
                      ),
                    ),
                  ],
                ),
              ),
              const Gap.md(),
              FieldBlock(
                label: 'Metal finish',
                child: ChoiceWrap<MetalFinish>(
                  values: MetalFinish.values,
                  selected: spec.metalFinish,
                  labelOf: (value) => value.label,
                  onSelected: (value) => controller.editProductSpec(metalFinish: Opt(value)),
                ),
              ),
              if (category.usesRingSize || category == ProductCategory.bangle) ...[
                const Gap.md(),
                FieldBlock(
                  label: 'Band profile',
                  helper: 'The cross-section of the band, as seen end-on.',
                  child: ChoiceWrap<BandProfile>(
                    values: BandProfile.values,
                    selected: spec.bandProfile,
                    labelOf: (value) => value.label,
                    onSelected: (value) => controller.editProductSpec(bandProfile: Opt(value)),
                  ),
                ),
              ],
              if (category.usesRingSize) ...[
                const Gap.md(),
                FieldBlock(
                  label: 'Fit',
                  helper: 'Comfort fit is domed inside and wears a half size looser.',
                  child: ChoiceWrap<FitProfile>(
                    values: FitProfile.values,
                    selected: spec.fit,
                    labelOf: (value) => value.label,
                    onSelected: (value) => controller.editProductSpec(fit: Opt(value)),
                  ),
                ),
              ],
              const Gap.md(),
              FieldBlock(
                label: 'Side stones',
                helper: 'How the accents are set, if there are any.',
                child: ChoiceWrap<SideStoneSetting>(
                  values: SideStoneSetting.values,
                  selected: spec.sideStones,
                  labelOf: (value) => value.label,
                  onSelected: (value) => controller.editProductSpec(sideStones: Opt(value)),
                ),
              ),
            ],
          ),
        ),
        const Gap.md(),
        DhSectionCard(
          title: 'What matters most',
          subtitle: 'The one thing to protect if a compromise has to be made.',
          leading: const Icon(Icons.psychology_outlined),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableTileGroup<DesignIntent>(
                values: DesignIntent.values,
                selected: spec.designIntent,
                dense: true,
                labelOf: (value) => value.label,
                blurbOf: (value) => switch (value) {
                  DesignIntent.matchExactly =>
                    'Follow the reference. Deviations come back to us for approval.',
                  DesignIntent.showOffStone =>
                    'Maximise the stone\'s presence — finer metal, higher setting.',
                  DesignIntent.strongAndSafe =>
                    'Daily wear. Heavier prongs, thicker shank, lower profile.',
                  DesignIntent.other => 'Something else — say what below.',
                },
                iconOf: (value) => switch (value) {
                  DesignIntent.matchExactly => Icons.compare_outlined,
                  DesignIntent.showOffStone => Icons.auto_awesome_outlined,
                  DesignIntent.strongAndSafe => Icons.shield_outlined,
                  DesignIntent.other => Icons.edit_note_outlined,
                },
                onChanged: (value) => controller.editProductSpec(designIntent: Opt(value)),
              ),
              OtherDetailField(
                visible: spec.designIntent?.needsDetail ?? false,
                value: spec.designIntentNote,
                label: 'What the client actually asked for',
                hint: 'Match her grandmother\'s ring but in platinum',
                onChanged: (value) => controller.editProductSpec(
                  designIntentNote: Opt(value),
                  delay: SaveDelay.typing,
                ),
              ),
            ],
          ),
        ),
        const Gap.md(),
        DhSectionCard(
          title: 'Fit and dimensions',
          subtitle: _dimensionSubtitle(category),
          leading: const Icon(Icons.straighten_rounded),
          child: _Dimensions(spec: spec, category: category, controller: controller),
        ),
        const Gap.md(),
        DhSectionCard(
          title: 'Design notes',
          subtitle: 'Anything the fields above cannot hold.',
          leading: const Icon(Icons.notes_outlined),
          child: IntakeTextField(
            value: spec.notes,
            maxLines: 5,
            hint: 'Milgrain on the bezel. Client hates yellow gold. Engraving inside the shank: '
                '"14.02.2026".',
            onChanged: (value) => controller.editProductSpec(
              notes: Opt(value),
              delay: SaveDelay.typing,
            ),
          ),
        ),
      ],
    );
  }

  static String _dimensionSubtitle(ProductCategory category) {
    if (category.usesRingSize) return 'Indian sizing is what we cut to.';
    if (category.usesInnerDiameter) return 'Measured inside, across the widest point.';
    if (category.usesLength) return 'End to end, clasp included.';
    if (category.usesDrop) return 'From the top of the fitting to the lowest point.';
    return 'Record the measurements this piece needs in the notes below.';
  }
}

/// The conditional half of the step. The mockups had no swap at all — a necklace order carried a
/// ring size field, and nothing carried a chain length.
final class _Dimensions extends StatelessWidget {
  const _Dimensions({
    required this.spec,
    required this.category,
    required this.controller,
  });

  final ProductSpec spec;
  final ProductCategory category;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[];

    if (category.usesRingSize) {
      blocks.add(
        FieldBlock(
          label: 'Ring size (India)',
          helper: 'Stored with the US number and UK letter, so any of the three can be quoted '
              'back later.',
          child: RingSizeField(
            india: spec.ringSizeIn,
            onChanged: (size) => controller.editProductSpec(
              ringSizeIn: Opt(size.india.toDouble()),
              ringSizeUs: Opt(size.us),
              ringSizeUk: Opt(size.uk),
            ),
            onCleared: () => controller.editProductSpec(
              ringSizeIn: const Opt<double>.clear(),
              ringSizeUs: const Opt<double>.clear(),
              ringSizeUk: const Opt<String>.clear(),
            ),
          ),
        ),
      );
      blocks.add(
        FieldBlock(
          label: 'Band width',
          child: StepperField(
            value: spec.bandWidthMm ?? 2.0,
            min: 0.8,
            max: 15,
            step: 0.1,
            decimals: 1,
            unit: 'mm',
            helperText: 'Across the shank at the back of the finger.',
            onChanged: (value) => controller.editProductSpec(
              bandWidthMm: Opt(value),
              delay: SaveDelay.dragging,
            ),
          ),
        ),
      );
    }

    if (category.usesInnerDiameter) {
      blocks.add(
        FieldBlock(
          label: 'Inner diameter',
          child: StepperField(
            value: spec.innerDiaMm ?? 58.0,
            min: 30,
            max: 90,
            step: 0.5,
            decimals: 1,
            unit: 'mm',
            helperText: 'Measured inside. A standard Indian bangle runs 2.4 to 2.8 (56–66 mm).',
            onChanged: (value) => controller.editProductSpec(
              innerDiaMm: Opt(value),
              delay: SaveDelay.dragging,
            ),
          ),
        ),
      );
    }

    if (category.usesLength) {
      blocks.add(
        FieldBlock(
          label: 'Length',
          child: StepperField(
            value: spec.lengthMm ?? 420.0,
            min: 80,
            max: 1200,
            step: 5,
            decimals: 0,
            unit: 'mm',
            helperText: 'End to end including the clasp. A 16-inch choker is 406 mm.',
            onChanged: (value) => controller.editProductSpec(
              lengthMm: Opt(value),
              delay: SaveDelay.dragging,
            ),
          ),
        ),
      );
    }

    if (category.usesDrop) {
      blocks.add(
        FieldBlock(
          label: 'Drop',
          child: StepperField(
            value: spec.dropMm ?? 18.0,
            min: 2,
            max: 200,
            step: 0.5,
            decimals: 1,
            unit: 'mm',
            helperText: 'From the top of the post or bail to the lowest point.',
            onChanged: (value) => controller.editProductSpec(
              dropMm: Opt(value),
              delay: SaveDelay.dragging,
            ),
          ),
        ),
      );
    }

    if (blocks.isEmpty) {
      return const NoteStrip(
        text: 'This category has no fixed dimension field. Put the measurements the bench needs '
            'into the design notes below, with the units written out.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const Gap.md(),
          blocks[i],
        ],
      ],
    );
  }
}
