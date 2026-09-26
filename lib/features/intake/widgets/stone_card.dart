/// One stone, and one melee parcel, as editable cards.
///
/// The stone requirements screen is the worst version drift in the corpus — seven variants, none
/// complete, each redesign making a different subset editable and dropping something the one
/// before it had. D-012 settles it as the union, and this card is that union: the typed carat
/// from the original screen, the discrete L/W/D from `refined_inputs`, the grade ladders from
/// `interactive_inputs`, the custody block from `customer_supplied`, Moissanite, and — above all
/// — **origin**.
///
/// `StoneOrigin` survived in exactly one file out of 46. Natural versus lab grown changes the
/// valuation, the disclosure obligation and which lab will certify it, so here it is never
/// hidden, never defaulted and never inferred from the stone type. It sits directly under the
/// species, before shape, where it cannot be scrolled past.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/save_queue.dart';
import 'package:dhanaos/features/intake/widgets/custody_card.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

// ================================================================= stone

final class StoneCard extends ConsumerStatefulWidget {
  const StoneCard({
    super.key,
    required this.draft,
    required this.stone,
    required this.controller,
    required this.index,
    this.startExpanded = false,
  });

  final IntakeDraft draft;
  final Stone stone;
  final IntakeController controller;

  /// Position within its role, so two side stones are distinguishable at a glance.
  final int index;
  final bool startExpanded;

  @override
  ConsumerState<StoneCard> createState() => _StoneCardState();
}

class _StoneCardState extends ConsumerState<StoneCard> {
  late bool _expanded = widget.startExpanded;
  bool _busy = false;

  Stone get _stone => widget.stone;
  IntakeController get _controller => widget.controller;

  Future<void> _edit(Future<String?> Function() action) => runIntake(context, action);

  Future<void> _delete() async {
    final confirmed = await confirmAction(
      context,
      title: 'Remove ${_stone.displayTitle}?',
      message: _stone.hasCustodyRecord
          ? 'This stone has a custody record against it — the client has a receipt with this '
              'job on it. Removing it here does not hand the stone back.'
          : 'The stone and everything recorded about it come off this job order.',
      confirmLabel: 'Remove the stone',
    );
    if (!confirmed || !mounted) return;
    await _edit(() => _controller.removeStone(_stone.id));
  }

  Future<void> _addPhoto() async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 92);
    } on Exception catch (error) {
      if (!mounted) return;
      showFailure(
        context,
        'The camera could not be opened. Check that DhanaOS has camera permission. ($error)',
      );
      return;
    }
    final shot = picked;
    if (shot == null || !mounted) return;
    setState(() => _busy = true);
    // The vault bucket, not customer-visible storage: a photograph of a client's stone is
    // valuation material.
    final failure = await _controller.attachStonePhoto(
      stoneId: _stone.id,
      file: File(shot.path),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) showFailure(context, failure);
  }

  @override
  Widget build(BuildContext context) {
    final stone = _stone;
    final open = stone.openQuestions;

    return DhCard(
      padding: EdgeInsets.zero,
      accent: open.isEmpty ? context.dh.success : context.dh.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, open),
          if (_expanded) ...[
            Divider(height: 1, thickness: 1, color: context.dh.outlineVariant),
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _sourcing(context),
                  const Gap.md(),
                  _species(context),
                  const Gap.md(),
                  _size(context),
                  const Gap.md(),
                  if (stone.usesFourCs) _fourCs(context) else _colouredStone(context),
                  const Gap.md(),
                  _certification(context),
                  const Gap.md(),
                  _photoAndNotes(context),
                  if (stone.isCustomerSupplied) ...[
                    const Gap.md(),
                    CustodyCard(
                      draft: widget.draft,
                      stone: stone,
                      controller: _controller,
                    ),
                  ],
                  const Gap.md(),
                  TextButton.icon(
                    onPressed: _busy ? null : _delete,
                    style: TextButton.styleFrom(foregroundColor: context.scheme.error),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: const Text('Remove this stone'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- header

  Widget _header(BuildContext context, List<String> open) {
    final stone = _stone;
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.index > 0
                              ? '${stone.displayTitle} ${widget.index + 1}'
                              : stone.displayTitle,
                          style: context.text.titleMedium
                              ?.copyWith(color: context.scheme.onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (stone.origin != null) ...[
                        const SizedBox(width: Spacing.sm),
                        StatusChip.origin(stone.origin!, dense: true),
                      ],
                    ],
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    stone.gradeSummary,
                    style: AppTheme.mono(size: 12.5, color: context.scheme.onSurfaceVariant),
                    maxLines: 2,
                  ),
                  const SizedBox(height: Spacing.sm),
                  Wrap(
                    spacing: Spacing.sm,
                    runSpacing: Spacing.xs,
                    children: [
                      StatusChip(
                        label: stone.sourcing.label,
                        dense: true,
                        tone: stone.isCustomerSupplied ? ChipTone.warning : ChipTone.neutral,
                        icon: stone.isCustomerSupplied ? Icons.shield_outlined : null,
                      ),
                      if (open.isEmpty)
                        const StatusChip(
                          label: 'Complete',
                          dense: true,
                          tone: ChipTone.success,
                          icon: Icons.check_rounded,
                        )
                      else
                        StatusChip(
                          label: '${open.length} to answer',
                          dense: true,
                          tone: ChipTone.warning,
                          tooltip: open.join(', '),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Icon(
              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              color: context.scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- sourcing

  Widget _sourcing(BuildContext context) {
    return FieldBlock(
      label: 'Where the stone comes from',
      helper: _stone.sourcing.blurb,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // D-012: the mockups' segmented control meant timing on one variant and sourcing on
          // another. Resolved to sourcing, because that is what decides custody.
          DhSegmented<StoneSourcing>(
            value: _stone.sourcing,
            segments: const [
              DhSegment(
                value: StoneSourcing.needsSourcing,
                label: 'We source',
                icon: Icons.travel_explore_outlined,
              ),
              DhSegment(
                value: StoneSourcing.inStock,
                label: 'In stock',
                icon: Icons.inventory_2_outlined,
              ),
              DhSegment(
                value: StoneSourcing.customerSupplied,
                label: 'Client\'s',
                icon: Icons.shield_outlined,
              ),
            ],
            onChanged: (value) => _edit(
              () => _controller.editStone(_stone.id, sourcing: value),
            ),
          ),
          if (_stone.isCustomerSupplied) ...[
            const Gap.sm(),
            const NoteStrip(
              tone: NoteTone.consequence,
              icon: Icons.shield_outlined,
              text: 'A client-supplied stone needs a full custody record before this step will '
                  'pass — declared value, receipt number, date and the client\'s acknowledgement '
                  'of the risk terms. The card for it is at the bottom of this stone.',
            ),
          ] else if (_stone.sourcing == StoneSourcing.inStock) ...[
            const Gap.sm(),
            const NoteStrip(
              text: 'The vault allocation is made when the job reaches production. Specify the '
                  'stone you want here and the keeper matches it against stock.',
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- species + origin

  Widget _species(BuildContext context) {
    final stone = _stone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldBlock(
          label: 'Stone type',
          helper: 'Diamond and moissanite are graded on the 4Cs. Coloured stones are not, so '
              'the questions below change with this answer.',
          child: ChoiceWrap<StoneType>(
            values: StoneType.values,
            selected: stone.stoneType,
            labelOf: (value) => value.label,
            onSelected: (value) => _edit(
              () => _controller.editStone(stone.id, stoneType: Opt(value)),
            ),
          ),
        ),
        const Gap.md(),
        // The field to watch (D-012). Always visible, never defaulted.
        FieldBlock(
          label: 'Origin',
          trailing: const StatusChip(
            label: 'Always stated',
            tone: ChipTone.warning,
            dense: true,
            icon: Icons.priority_high_rounded,
          ),
          helper: 'Natural or lab grown changes the valuation, what has to be disclosed to the '
              'buyer, and which lab will certify it. There is no sensible default.',
          child: ChoiceWrap<StoneOrigin>(
            values: StoneOrigin.values,
            selected: stone.origin,
            labelOf: (value) => value.label,
            onSelected: (value) => _edit(
              () => _controller.editStone(stone.id, origin: Opt(value)),
            ),
          ),
        ),
        if (stone.origin == null) ...[
          const Gap.sm(),
          const NoteStrip(
            tone: NoteTone.consequence,
            icon: Icons.priority_high_rounded,
            text: 'Unanswered. This step will not pass without it — a stone sold without its '
                'origin stated is a disclosure failure, not a missing field.',
          ),
        ],
        const Gap.md(),
        FieldBlock(
          label: 'Shape',
          child: ChoiceWrap<StoneShape>(
            values: StoneShape.values,
            selected: stone.shape,
            labelOf: (value) => value.label,
            onSelected: (value) => _edit(
              () => _controller.editStone(stone.id, shape: Opt(value)),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- size

  Widget _size(BuildContext context) {
    final stone = _stone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Typed carat, which the later redesigns replaced with preset chips — so 1.07 ct, the
        // weight a real stone actually is, became unenterable.
        StepperField.carat(
          value: stone.carat ?? 1.0,
          label: 'Carat weight',
          helperText: 'Type it or step it. Hundredths, the way a stone is quoted.',
          trailing: stone.carat == null ? const StatusChip(label: 'Not set', dense: true) : null,
          onChanged: (value) => _edit(
            () => _controller.editStone(
              stone.id,
              carat: Opt(value),
              delay: SaveDelay.dragging,
            ),
          ),
        ),
        const Gap.md(),
        Text(
          'MEASUREMENTS',
          style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
        ),
        const SizedBox(height: Spacing.sm),
        // `refined_inputs` split the earlier "Dimensions (L x W x D mm)" free-text box into
        // three numbers. Kept discrete, joined only for display.
        _mm(context, 'Length', stone.lengthMm,
            (v) => _controller.editStone(stone.id, lengthMm: Opt(v), delay: SaveDelay.dragging)),
        const Gap.sm(),
        _mm(context, 'Width', stone.widthMm,
            (v) => _controller.editStone(stone.id, widthMm: Opt(v), delay: SaveDelay.dragging)),
        const Gap.sm(),
        _mm(context, 'Depth', stone.depthMm,
            (v) => _controller.editStone(stone.id, depthMm: Opt(v), delay: SaveDelay.dragging)),
        const Gap.sm(),
        Text(
          stone.dimensionsText,
          style: AppTheme.mono(size: 13, color: context.scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _mm(
    BuildContext context,
    String label,
    double? value,
    Future<String?> Function(double) write,
  ) =>
      StepperField(
        value: value ?? 6.0,
        min: 0.5,
        max: 60,
        step: 0.01,
        decimals: 2,
        unit: 'mm',
        label: label,
        trailing: value == null ? const StatusChip(label: 'Not set', dense: true) : null,
        onChanged: (v) => _edit(() => write(v)),
      );

  // ---------------------------------------------------------------- 4Cs

  Widget _fourCs(BuildContext context) {
    final stone = _stone;
    return DhCard(
      tone: DhCardTone.inset,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'GRADING · 4Cs',
            style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            'Pick the exact grade, or type the band the customer will accept. Doing one clears '
            'the other — "F" and "F-G" are different promises.',
            style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const Gap.md(),
          FieldBlock(
            label: 'Colour',
            child: ChoiceWrap<DiamondColor>(
              values: DiamondColor.values,
              selected: stone.color,
              mono: true,
              labelOf: (value) => value.label,
              onSelected: (value) => _edit(
                () => _controller.editStone(
                  stone.id,
                  color: Opt(value),
                  colorRange: const Opt<String>.clear(),
                ),
              ),
            ),
          ),
          const Gap.sm(),
          IntakeTextField(
            value: stone.colorRange,
            label: 'or an accepted colour range',
            hint: 'F–G',
            mono: true,
            textCapitalization: TextCapitalization.characters,
            onChanged: (value) => _edit(
              () => _controller.editStone(
                stone.id,
                colorRange: Opt(value),
                color: value.trim().isEmpty ? null : const Opt<DiamondColor>.clear(),
                delay: SaveDelay.typing,
              ),
            ),
          ),
          const Gap.md(),
          FieldBlock(
            label: 'Clarity',
            child: ChoiceWrap<DiamondClarity>(
              values: DiamondClarity.values,
              selected: stone.clarity,
              mono: true,
              labelOf: (value) => value.label,
              onSelected: (value) => _edit(
                () => _controller.editStone(
                  stone.id,
                  clarity: Opt(value),
                  clarityRange: const Opt<String>.clear(),
                ),
              ),
            ),
          ),
          const Gap.sm(),
          IntakeTextField(
            value: stone.clarityRange,
            label: 'or an accepted clarity range',
            hint: 'VS1–VS2',
            mono: true,
            textCapitalization: TextCapitalization.characters,
            onChanged: (value) => _edit(
              () => _controller.editStone(
                stone.id,
                clarityRange: Opt(value),
                clarity: value.trim().isEmpty ? null : const Opt<DiamondClarity>.clear(),
                delay: SaveDelay.typing,
              ),
            ),
          ),
          const Gap.md(),
          FieldBlock(
            label: 'Cut',
            child: ChoiceWrap<DiamondCut>(
              values: DiamondCut.values,
              selected: stone.cut,
              labelOf: (value) => value.label,
              onSelected: (value) => _edit(
                () => _controller.editStone(stone.id, cut: Opt(value)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- coloured stone

  Widget _colouredStone(BuildContext context) {
    final stone = _stone;
    return DhCard(
      tone: DhCardTone.inset,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'COLOURED STONE DETAIL',
            style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            'A ruby is not graded on the 4Cs. What sets its value is whether it has been '
            'treated and where it came from — which is why the mockups\' fixed 4C table was '
            'the wrong question here.',
            style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const Gap.md(),
          IntakeTextField(
            value: stone.treatment,
            label: 'Treatment',
            hint: 'Unheated · Heated · Oiled (minor)',
            onChanged: (value) => _edit(
              () => _controller.editStone(
                stone.id,
                treatment: Opt(value),
                delay: SaveDelay.typing,
              ),
            ),
          ),
          const Gap.md(),
          IntakeTextField(
            value: stone.provenance,
            label: 'Provenance',
            hint: 'Mogok, Myanmar',
            onChanged: (value) => _edit(
              () => _controller.editStone(
                stone.id,
                provenance: Opt(value),
                delay: SaveDelay.typing,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- certification

  Widget _certification(BuildContext context) {
    final stone = _stone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ToggleRow(
          title: 'This stone needs a certificate',
          blurb: 'Adds days to the plan and a cost line to the quote. Lab-grown stones are '
              'certified by IGI far more often than by GIA.',
          icon: Icons.workspace_premium_outlined,
          value: stone.certRequired,
          onChanged: (value) => _edit(
            () => _controller.editStone(stone.id, certRequired: value),
          ),
        ),
        if (stone.certRequired) ...[
          const Gap.sm(),
          FieldBlock(
            label: 'Certifying lab',
            child: ChoiceWrap<CertLab>(
              // `none` belongs to the job-level acceptance question, not to one stone: a stone
              // that needs no certificate is the toggle above turned off.
              values: [
                for (final lab in CertLab.values)
                  if (!lab.skipsStage) lab,
              ],
              selected: stone.certLab,
              labelOf: (value) => value.label,
              onSelected: (value) => _edit(
                () => _controller.editStone(stone.id, certLab: Opt(value)),
              ),
            ),
          ),
          const Gap.sm(),
          IntakeTextField(
            value: stone.certNumber,
            label: 'Certificate number',
            helper: 'Fill this in when the stone already has a report. Leave it blank and the '
                'certification stage will chase it.',
            hint: '2211457890',
            mono: true,
            onChanged: (value) => _edit(
              () => _controller.editStone(
                stone.id,
                certNumber: Opt(value),
                delay: SaveDelay.typing,
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------- photo + notes

  Widget _photoAndNotes(BuildContext context) {
    final stone = _stone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldBlock(
          label: 'Stone photograph',
          helper: 'Filed to the vault, not to customer-visible storage. For a client-supplied '
              'stone this is the picture that proves what came in.',
          child: stone.photoAttachment == null
              ? AddAttachmentTile(
                  onTap: _addPhoto,
                  label: 'Photograph the stone',
                  icon: Icons.photo_camera_outlined,
                  hint: 'Loose, on the paper, under the loupe light',
                )
              : Row(
                  children: [
                    Icon(Icons.check_circle_outline_rounded, size: 18, color: context.dh.success),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        'Photograph on file in the vault.',
                        style: context.text.bodySmall
                            ?.copyWith(color: context.scheme.onSurfaceVariant),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _addPhoto,
                      child: const Text('Replace'),
                    ),
                  ],
                ),
        ),
        const Gap.md(),
        IntakeTextField(
          value: stone.notes,
          label: 'Stone notes',
          maxLines: 3,
          hint: 'Client wants the inscription facing the palm. Slight chip on the girdle — '
              'photographed at goods-in.',
          onChanged: (value) => _edit(
            () => _controller.editStone(
              stone.id,
              notes: Opt(value),
              delay: SaveDelay.typing,
            ),
          ),
        ),
      ],
    );
  }
}

// ================================================================= melee

/// Melee is bought by the parcel, not specified stone by stone. The mockups' dashboard warned
/// "Melee diamonds count mismatch at receiving" with nothing behind the alert — this is the
/// specification that alert would have been checked against.
final class MeleeCard extends ConsumerStatefulWidget {
  const MeleeCard({
    super.key,
    required this.parcel,
    required this.controller,
  });

  final MeleeParcel parcel;
  final IntakeController controller;

  @override
  ConsumerState<MeleeCard> createState() => _MeleeCardState();
}

class _MeleeCardState extends ConsumerState<MeleeCard> {
  bool _expanded = false;

  MeleeParcel get _parcel => widget.parcel;

  Future<void> _edit(Future<String?> Function() action) => runIntake(context, action);

  Future<void> _delete() async {
    final confirmed = await confirmAction(
      context,
      title: 'Remove this melee parcel?',
      message: 'The parcel and its size band, count and weight come off the job order.',
      confirmLabel: 'Remove the parcel',
    );
    if (!confirmed || !mounted) return;
    await _edit(() => widget.controller.removeMelee(_parcel.id));
  }

  @override
  Widget build(BuildContext context) {
    final parcel = _parcel;
    final average = parcel.avgCaratPerPiece;

    return DhCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                '${parcel.stoneType.label} melee · ${parcel.shape.label}',
                                style: context.text.titleMedium
                                    ?.copyWith(color: context.scheme.onSurface),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (parcel.origin != null) ...[
                              const SizedBox(width: Spacing.sm),
                              StatusChip.origin(parcel.origin!, dense: true),
                            ],
                          ],
                        ),
                        const SizedBox(height: Spacing.xs),
                        Text(
                          parcel.summary,
                          style: AppTheme.mono(
                            size: 12.5,
                            color: context.scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    color: context.scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, thickness: 1, color: context.dh.outlineVariant),
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FieldBlock(
                    label: 'Sourcing',
                    child: DhSegmented<StoneSourcing>(
                      value: parcel.sourcing,
                      dense: true,
                      segments: const [
                        DhSegment(value: StoneSourcing.needsSourcing, label: 'We source'),
                        DhSegment(value: StoneSourcing.inStock, label: 'In stock'),
                        DhSegment(value: StoneSourcing.customerSupplied, label: 'Client\'s'),
                      ],
                      onChanged: (value) => _edit(
                        () => widget.controller.editMelee(parcel.id, sourcing: value),
                      ),
                    ),
                  ),
                  const Gap.md(),
                  FieldBlock(
                    label: 'Stone type',
                    child: ChoiceWrap<StoneType>(
                      values: StoneType.values,
                      selected: parcel.stoneType,
                      labelOf: (value) => value.label,
                      onSelected: (value) => _edit(
                        () => widget.controller.editMelee(parcel.id, stoneType: value),
                      ),
                    ),
                  ),
                  const Gap.md(),
                  FieldBlock(
                    label: 'Origin',
                    trailing: const StatusChip(
                      label: 'Always stated',
                      tone: ChipTone.warning,
                      dense: true,
                      icon: Icons.priority_high_rounded,
                    ),
                    helper: 'Lab-grown melee is a different price and a different disclosure '
                        'from natural melee. It is asked here for the same reason it is asked '
                        'of the centre stone.',
                    child: ChoiceWrap<StoneOrigin>(
                      values: StoneOrigin.values,
                      selected: parcel.origin,
                      labelOf: (value) => value.label,
                      onSelected: (value) => _edit(
                        () => widget.controller.editMelee(parcel.id, origin: Opt(value)),
                      ),
                    ),
                  ),
                  const Gap.md(),
                  FieldBlock(
                    label: 'Shape',
                    child: ChoiceWrap<StoneShape>(
                      values: StoneShape.values,
                      selected: parcel.shape,
                      labelOf: (value) => value.label,
                      onSelected: (value) => _edit(
                        () => widget.controller.editMelee(parcel.id, shape: value),
                      ),
                    ),
                  ),
                  const Gap.md(),
                  StepperField(
                    value: parcel.sizeMinMm ?? 1.2,
                    min: 0.5,
                    max: 6,
                    step: 0.05,
                    decimals: 2,
                    unit: 'mm',
                    label: 'Smallest stone',
                    onChanged: (value) => _edit(
                      () => widget.controller.editMelee(
                        parcel.id,
                        sizeMinMm: Opt(value),
                        delay: SaveDelay.dragging,
                      ),
                    ),
                  ),
                  const Gap.sm(),
                  StepperField(
                    value: parcel.sizeMaxMm ?? 1.5,
                    min: 0.5,
                    max: 6,
                    step: 0.05,
                    decimals: 2,
                    unit: 'mm',
                    label: 'Largest stone',
                    onChanged: (value) => _edit(
                      () => widget.controller.editMelee(
                        parcel.id,
                        sizeMaxMm: Opt(value),
                        delay: SaveDelay.dragging,
                      ),
                    ),
                  ),
                  const Gap.md(),
                  StepperField.count(
                    value: parcel.pieceCount ?? 0,
                    min: 0,
                    max: 999,
                    label: 'Pieces',
                    unit: 'pc',
                    helperText: 'Counted at receiving against this figure.',
                    onChanged: (value) => _edit(
                      () => widget.controller.editMelee(
                        parcel.id,
                        pieceCount: Opt(value),
                        delay: SaveDelay.dragging,
                      ),
                    ),
                  ),
                  const Gap.sm(),
                  StepperField(
                    value: parcel.totalCtw ?? 0,
                    min: 0,
                    max: 50,
                    step: 0.01,
                    decimals: 2,
                    unit: 'ct tw',
                    label: 'Total carat weight',
                    helperText: average == null
                        ? 'Weighed in as one parcel.'
                        : 'Averages ${average.toStringAsFixed(3)} ct a stone.',
                    onChanged: (value) => _edit(
                      () => widget.controller.editMelee(
                        parcel.id,
                        totalCtw: Opt(value),
                        delay: SaveDelay.dragging,
                      ),
                    ),
                  ),
                  const Gap.md(),
                  IntakeTextField(
                    value: parcel.colorRange,
                    label: 'Colour range',
                    hint: 'F–G',
                    mono: true,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (value) => _edit(
                      () => widget.controller.editMelee(
                        parcel.id,
                        colorRange: Opt(value),
                        delay: SaveDelay.typing,
                      ),
                    ),
                  ),
                  const Gap.sm(),
                  IntakeTextField(
                    value: parcel.clarityRange,
                    label: 'Clarity range',
                    hint: 'VS–SI',
                    mono: true,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (value) => _edit(
                      () => widget.controller.editMelee(
                        parcel.id,
                        clarityRange: Opt(value),
                        delay: SaveDelay.typing,
                      ),
                    ),
                  ),
                  const Gap.md(),
                  TextButton.icon(
                    onPressed: _delete,
                    style: TextButton.styleFrom(foregroundColor: context.scheme.error),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: const Text('Remove this parcel'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
