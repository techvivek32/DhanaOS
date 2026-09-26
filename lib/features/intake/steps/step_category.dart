/// Step 3 — which piece, and which style of it.
///
/// D-012 splits `product_selection`'s flat list in two. The mockup offered eight items and then
/// every downstream screen displayed "Engagement Ring" — which is a sub-style, not a category. A
/// ring and an eternity band are the same category and completely different builds, so both are
/// stored: `jobs.category` drives which dimensions exist, `jobs.sub_style` drives what the CAD
/// designer actually draws.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
import 'package:dhanaos/features/intake/steps/step_shell.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class StepCategory extends ConsumerWidget {
  const StepCategory({super.key, required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.intake(jobKey);
    final category = draft.category;
    final styles =
        category == null ? const <ProductSubStyle>[] : ProductSubStyle.forCategory(category);

    return IntakeStepScaffold(
      draft: draft,
      jobKey: jobKey,
      step: IntakeStep.category,
      footerNote: category == null
          ? null
          : 'Changing the category later drops the dimensions it cannot use — a ring size does '
              'not follow a piece onto a necklace.',
      children: [
        DhSectionCard(
          title: 'Category',
          subtitle: 'This decides which measurements the next step asks for.',
          leading: const Icon(Icons.diamond_outlined),
          child: LayoutBuilder(
            builder: (layoutContext, constraints) {
              // Two columns on a phone, three once there is room — the tiles are icon-plus-label
              // so they stay legible either way.
              final columns = constraints.maxWidth >= 520 ? 3 : 2;
              final width =
                  (constraints.maxWidth - (columns - 1) * Spacing.sm) / columns;
              return Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  for (final value in ProductCategory.values)
                    SizedBox(
                      width: width,
                      child: _CategoryTile(
                        category: value,
                        selected: value == category,
                        onTap: () => controller.setCategory(value),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const Gap.md(),
        if (category == null)
          const NoteStrip(
            text: 'Pick a category and the styles it is built in will appear here.',
          )
        else
          DhSectionCard(
            title: 'Style',
            subtitle: 'What the customer asked for, in the trade\'s own words.',
            leading: const Icon(Icons.style_outlined),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ChoiceWrap<ProductSubStyle>(
                  values: styles,
                  selected: draft.subStyle,
                  labelOf: (value) => value.label,
                  onSelected: (value) => controller.setSubStyle(value),
                ),
                if (draft.subStyle == ProductSubStyle.other) ...[
                  const Gap.sm(),
                  NoteStrip(
                    tone: NoteTone.consequence,
                    text: 'Describe the style in the design notes on the next step — '
                        '"${category.label} · Other" is not something the bench can build from.',
                  ),
                ],
              ],
            ),
          ),
        const Gap.md(),
        if (category != null)
          DhSectionCard(
            title: 'What this step decides',
            leading: const Icon(Icons.straighten_rounded),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DataPair(
                  label: 'Sizing question on the next step',
                  value: _sizingSentence(category),
                ),
                const Gap.sm(),
                DataPair.mono(
                  label: 'Piece',
                  value: draft.subStyle == null
                      ? category.label
                      : '${draft.subStyle!.label} · ${category.label}',
                  emphasis: DataEmphasis.strong,
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _sizingSentence(ProductCategory category) {
    if (category.usesRingSize) {
      return 'Ring size, Indian scale, with the US and UK equivalents shown beside it.';
    }
    if (category.usesInnerDiameter && category.usesLength) {
      return 'Inner diameter and length in millimetres.';
    }
    if (category.usesInnerDiameter) return 'Inner diameter in millimetres.';
    if (category.usesLength) return 'Chain length in millimetres.';
    if (category.usesDrop) return 'Drop length in millimetres.';
    return 'Free dimensions — record them in the design notes.';
  }
}

final class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final ProductCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: DhCard(
        onTap: onTap,
        selected: selected,
        tone: DhCardTone.raised,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm + Spacing.xs,
          vertical: Spacing.md - 2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: context.motion(Motion.fast),
              curve: context.motionCurve,
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: selected ? scheme.secondary : dh.surfaceContainerHigh,
                borderRadius: Radii.rMd,
              ),
              child: Center(
                child: Icon(
                  _iconFor(category),
                  size: 20,
                  color: selected ? scheme.onSecondary : scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              category.label,
              style: context.text.titleMedium?.copyWith(
                color: scheme.onSurface,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              _dimensionHint(category),
              style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  static String _dimensionHint(ProductCategory category) {
    if (category.usesRingSize) return 'RING SIZE';
    if (category.usesInnerDiameter && category.usesLength) return 'Ø + LENGTH';
    if (category.usesInnerDiameter) return 'INNER Ø';
    if (category.usesLength) return 'LENGTH';
    if (category.usesDrop) return 'DROP';
    return 'FREE FORM';
  }

  static IconData _iconFor(ProductCategory category) => switch (category) {
        ProductCategory.ring => Icons.circle_outlined,
        ProductCategory.earrings => Icons.water_drop_outlined,
        ProductCategory.necklace => Icons.linear_scale_rounded,
        ProductCategory.pendant => Icons.change_history_outlined,
        ProductCategory.bracelet => Icons.watch_outlined,
        ProductCategory.bangle => Icons.panorama_fish_eye_rounded,
        ProductCategory.brooch => Icons.star_outline_rounded,
        ProductCategory.other => Icons.more_horiz_rounded,
      };
}
