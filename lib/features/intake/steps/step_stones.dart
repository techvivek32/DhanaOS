/// Step 6 — stones.
///
/// D-012 rebuilds this step from `stone_requirements_refined_inputs`, with the grade ladders from
/// `interactive_inputs`, the custody card from `customer_supplied`, and — from the *original*
/// `stone_requirements`, which every later redesign quietly dropped — origin, Moissanite and a
/// typed carat weight.
///
/// Seven variants of this screen shipped and not one of them was complete. The rule this step
/// enforces instead of re-litigating them is `Stone.openQuestions`: a stone is buildable when it
/// has a species, an **origin**, a shape, a weight or a measurement, a lab if a certificate was
/// asked for, and a full custody record if it belongs to the client. The step passes when no
/// stone has an open question left.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/spec_repository.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
import 'package:dhanaos/features/intake/steps/step_shell.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/features/intake/widgets/stone_card.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class StepStones extends ConsumerStatefulWidget {
  const StepStones({super.key, required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  ConsumerState<StepStones> createState() => _StepStonesState();
}

class _StepStonesState extends ConsumerState<StepStones> {
  bool _busy = false;

  IntakeDraft get _draft => widget.draft;
  IntakeController get _controller => ref.intake(widget.jobKey);

  Future<void> _guard(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final failure = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) showFailure(context, failure);
  }

  /// The client's own stone is the reason the Reset Stone job type exists, so it is offered as
  /// its own action rather than buried behind a sourcing control the operator has to find.
  Future<void> _addStone(StoneRole role, {StoneSourcing? sourcing}) => _guard(
        () => _controller.addStone(
          role: role,
          sourcing: sourcing ??
              (_draft.jobType?.takesCustody == true && role == StoneRole.center
                  ? StoneSourcing.customerSupplied
                  : StoneSourcing.needsSourcing),
        ),
      );

  Future<void> _addMelee() => _guard(() => _controller.addMelee());

  /// The honest escape from this step: not "skip", but "there are no stones", which is
  /// REQ-GEM-03 answered No and written back to the metal spec where the rest of the app reads it.
  Future<void> _declareNoStones() async {
    if (_draft.stones.isNotEmpty || _draft.melee.isNotEmpty) {
      final confirmed = await confirmAction(
        context,
        title: 'Say this piece has no stones?',
        message: 'REQ-GEM-03 goes to No and this step is skipped from here on. The '
            '${_draft.stones.length + _draft.melee.length} entries already captured stay on the '
            'job order — answer Yes again and they are all still here.',
        confirmLabel: 'It is plain metal',
        cancelLabel: 'Keep the stones',
        destructive: false,
      );
      if (!confirmed || !mounted) return;
    }
    await _guard(() async {
      final failure = await _controller.editMetalSpec(gemstoneInset: const Opt(false));
      if (failure != null) return failure;
      return _controller.advance();
    });
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    final centre = [for (final s in draft.stones) if (s.role == StoneRole.center) s];
    final others = [for (final s in draft.stones) if (s.role != StoneRole.center) s];
    final gaps = draft.stoneGaps;

    return IntakeStepScaffold(
      draft: draft,
      jobKey: widget.jobKey,
      step: IntakeStep.stones,
      busy: _busy,
      secondaryLabel: 'No stones',
      onSecondary: _declareNoStones,
      footerNote: 'Everything here reaches the setter, the certifier and the customer\'s '
          'disclosure. Origin is on every stone because it changes all three.',
      children: [
        if (gaps.isNotEmpty) ...[
          _GapSummary(gaps: gaps),
          const Gap.md(),
        ],
        if (draft.stones.isEmpty && draft.melee.isEmpty) ...[
          DhCard(
            child: EmptyState(
              icon: Icons.diamond_outlined,
              title: 'No stones on this job yet',
              message: 'Add the centre stone first — it decides the setting, the certificate '
                  'and most of the price. Side stones and melee come after it.',
              actionLabel: 'Add the centre stone',
              onAction: () => _addStone(StoneRole.center),
              secondaryLabel: 'This piece is plain metal',
              onSecondary: _declareNoStones,
              compact: true,
            ),
          ),
          const Gap.md(),
        ],
        if (centre.isNotEmpty) ...[
          const _SectionHeading(
            label: 'Centre stone',
            note: 'The stone the piece is built around.',
          ),
          for (var i = 0; i < centre.length; i++) ...[
            StoneCard(
              key: ValueKey(centre[i].id),
              draft: draft,
              stone: centre[i],
              controller: _controller,
              index: i,
              // A stone with nothing answered opens ready to be filled in rather than making
              // the operator hunt for the disclosure triangle.
              startExpanded: centre.length == 1 && centre[i].openQuestions.length > 3,
            ),
            const Gap.sm(),
          ],
          const Gap.sm(),
        ],
        if (others.isNotEmpty) ...[
          const _SectionHeading(
            label: 'Side and accent stones',
            note: 'Individually specified stones that are not the centre.',
          ),
          for (var i = 0; i < others.length; i++) ...[
            StoneCard(
              key: ValueKey(others[i].id),
              draft: draft,
              stone: others[i],
              controller: _controller,
              index: i,
            ),
            const Gap.sm(),
          ],
          const Gap.sm(),
        ],
        if (draft.melee.isNotEmpty) ...[
          const _SectionHeading(
            label: 'Melee',
            note: 'Bought by the parcel and counted at receiving, not specified one by one.',
          ),
          for (final parcel in draft.melee) ...[
            MeleeCard(
              key: ValueKey(parcel.id),
              parcel: parcel,
              controller: _controller,
            ),
            const Gap.sm(),
          ],
          const Gap.sm(),
        ],
        DhSectionCard(
          title: 'Add a stone',
          leading: const Icon(Icons.add_circle_outline_rounded),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableTile(
                title: centre.isEmpty ? 'Centre stone' : 'Another centre stone',
                blurb: 'Three-stone and toi-et-moi rings have more than one.',
                icon: Icons.brightness_high_outlined,
                onTap: _busy ? null : () => _addStone(StoneRole.center),
              ),
              const Gap.sm(),
              SelectableTile(
                title: 'Side stone',
                blurb: 'Shoulder stones, trilliants, a baguette either side.',
                icon: Icons.blur_circular_outlined,
                onTap: _busy ? null : () => _addStone(StoneRole.side),
              ),
              const Gap.sm(),
              SelectableTile(
                title: 'Accent stone',
                blurb: 'A hidden halo, a birthstone under the gallery.',
                icon: Icons.auto_awesome_outlined,
                onTap: _busy ? null : () => _addStone(StoneRole.accent),
              ),
              const Gap.sm(),
              SelectableTile(
                title: 'Melee parcel',
                blurb: 'Pavé or channel stones, specified as a size band and a total weight.',
                icon: Icons.grain_outlined,
                onTap: _busy ? null : _addMelee,
              ),
              const Gap.sm(),
              SelectableTile(
                title: 'Client\'s own stone',
                blurb: 'Opens the goods-in custody record: declared value, receipt, risk terms.',
                icon: Icons.shield_outlined,
                badge: const StatusChip(
                  label: 'Custody',
                  tone: ChipTone.warning,
                  dense: true,
                ),
                onTap: _busy
                    ? null
                    : () => _addStone(
                          StoneRole.center,
                          sourcing: StoneSourcing.customerSupplied,
                        ),
              ),
            ],
          ),
        ),
        if (draft.stones.isNotEmpty || draft.melee.isNotEmpty) ...[
          const Gap.md(),
          _Totals(draft: draft),
        ],
      ],
    );
  }
}

// ================================================================= pieces

final class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.label, required this.note});

  final String label;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            note,
            style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// What is still unanswered, per stone, in the order the operator should fix it. This is the same
/// list `IntakeDraft.blockReasonFor` reduces to one sentence under the button — shown in full
/// here so nobody has to continue-and-fail their way through it.
final class _GapSummary extends StatelessWidget {
  const _GapSummary({required this.gaps});

  final List<StoneGap> gaps;

  @override
  Widget build(BuildContext context) {
    final custodyGaps = [for (final g in gaps) if (g.needsCustody) g];

    return DhSectionCard(
      title: 'Still to answer',
      subtitle: '${gaps.length} stone${gaps.length == 1 ? '' : 's'} cannot be built from what '
          'is recorded so far.',
      leading: const Icon(Icons.rule_outlined),
      accent: context.dh.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final gap in gaps) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.radio_button_unchecked_rounded,
                    size: 15,
                    color: context.dh.goldText,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          gap.label,
                          style: context.text.bodyMedium?.copyWith(
                            color: context.scheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          gap.missing.join(' · '),
                          style: AppTheme.mono(
                            size: 12,
                            color: context.scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (custodyGaps.isNotEmpty)
            const NoteStrip(
              tone: NoteTone.risk,
              icon: Icons.shield_outlined,
              text: 'A client\'s stone is in the workshop without a complete custody record. '
                  'Until the declared value, receipt number and risk acknowledgement are on '
                  'file, there is nothing written down about a stone we are responsible for.',
            ),
        ],
      ),
    );
  }
}

/// The figures the quote and the certificate will both quote back.
final class _Totals extends StatelessWidget {
  const _Totals({required this.draft});

  final IntakeDraft draft;

  @override
  Widget build(BuildContext context) {
    final custody = draft.custodyStones;
    var declared = draft.zero;
    for (final stone in custody) {
      declared += stone.declaredValue(draft.currency) ?? draft.zero;
    }
    final needsSourcing = [
      for (final s in draft.stones) if (s.needsProcurement) s,
      for (final p in draft.melee) if (p.needsProcurement) p,
    ].length;

    return DhSectionCard(
      title: 'Stone summary',
      leading: const Icon(Icons.summarize_outlined),
      child: DataPairGrid(
        children: [
          DataPair.mono(
            label: 'Total weight',
            value: '${draft.totalCarat.toStringAsFixed(2)} ct',
            emphasis: DataEmphasis.strong,
          ),
          DataPair.mono(
            label: 'Stones specified',
            value: '${draft.stones.length}',
          ),
          DataPair.mono(
            label: 'Melee parcels',
            value: '${draft.melee.length}',
          ),
          DataPair.mono(
            label: 'To source',
            value: '$needsSourcing',
            valueColor: needsSourcing == 0 ? null : context.dh.goldText,
          ),
          if (custody.isNotEmpty)
            DataPair.money(
              label: 'Client goods in our care',
              amount: declared,
              valueColor: context.dh.goldText,
            ),
        ],
      ),
    );
  }
}
