/// Step 1 — what kind of work is this?
///
/// D-012 takes export B's four types. Export C dropped `repair`, which would have written sizing
/// and restoration out of a workshop that earns real money from both.
///
/// Tapping a card chooses *and* advances, which is how `start_new_job_light` behaved and is right:
/// a four-way choice with an obvious answer should not need a second press. The selection is
/// scoped to the four cards — the mockup's handler ran over every element with the tile class and
/// so deselected the header's back button along with the tiles.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
import 'package:dhanaos/features/intake/steps/step_shell.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class StepJobType extends ConsumerStatefulWidget {
  const StepJobType({super.key, required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  ConsumerState<StepJobType> createState() => _StepJobTypeState();
}

class _StepJobTypeState extends ConsumerState<StepJobType> {
  bool _busy = false;

  Future<void> _choose(JobType type, {required bool advance}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final controller = ref.intake(widget.jobKey);
    final failure = await controller.chooseJobType(type);
    if (!mounted) return;
    if (failure != null) {
      setState(() => _busy = false);
      showFailure(context, failure);
      return;
    }
    if (advance) {
      final moved = await controller.advance();
      if (!mounted) return;
      if (moved != null) showFailure(context, moved);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final selected = draft.jobType;

    return IntakeStepScaffold(
      draft: draft,
      jobKey: widget.jobKey,
      step: IntakeStep.jobType,
      busy: _busy,
      showBack: false,
      footerNote: draft.hasJob
          ? 'Saved as ${draft.displayCode}. The real job number is minted when the order is '
              'committed on step 10.'
          : 'A draft number is reserved the moment you choose.',
      children: [
        // The four cards, and nothing else, carry the selected state.
        for (final type in JobType.values) ...[
          SelectableTile(
            title: type.label,
            blurb: type.blurb,
            icon: _iconFor(type),
            selected: selected == type,
            inGroup: true,
            badge: type.takesCustody
                ? const StatusChip(
                    label: 'Custody',
                    tone: ChipTone.warning,
                    icon: Icons.shield_outlined,
                    dense: true,
                  )
                : null,
            onTap: _busy ? null : () => _choose(type, advance: true),
          ),
          const Gap.sm(),
        ],
        const Gap.sm(),
        if (selected != null && selected.takesCustody)
          const NoteStrip(
            tone: NoteTone.consequence,
            icon: Icons.shield_outlined,
            text: 'Mounting a client\'s own stone means taking custody of it. The stone step will '
                'ask for the declared value, who verified it, the receipt number you gave the '
                'client, and their acknowledgement of the risk terms. None of that is optional.',
          )
        else if (selected == JobType.repair)
          const NoteStrip(
            text: 'Repairs and resizing still run the full rail — a resized shank is polished, '
                'QC-checked and hallmarked like anything else.',
          )
        else
          const NoteStrip(
            text: 'You can change this until the CAD is approved. After that the spec is what the '
                'bench is building against.',
          ),
      ],
    );
  }

  static IconData _iconFor(JobType type) => switch (type) {
        JobType.newCustomDesign => Icons.auto_awesome_outlined,
        JobType.recreateExisting => Icons.content_copy_outlined,
        JobType.resetStone => Icons.diamond_outlined,
        JobType.repair => Icons.handyman_outlined,
      };
}
