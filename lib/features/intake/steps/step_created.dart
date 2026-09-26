/// Step 11 — the job order exists.
///
/// D-001 lands here: the `DRAFT-992A` the wizard has been carrying since step 1 is gone and the
/// real code is on screen. `job_order_created` is the base, and it got the emotional beat right —
/// a confirmation, the number, what happens next. What it did not have was a number that came
/// from anywhere (five formats coexisted across the corpus, and all five folders named `*_dh_1048`
/// rendered a *different* id), a rail with fourteen stages in it, or an "Assign CAD Designer"
/// button that opened anything.
///
/// All three are real here. The code is minted by `fn_mint_job_code` under a row lock so two
/// devices committing at once cannot collide; the rail is the fourteen rows `fn_seed_job_stages`
/// wrote; and the assign button opens the team directory.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
import 'package:dhanaos/features/intake/intake_wizard.dart';
import 'package:dhanaos/features/intake/widgets/designer_picker.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final _dayFormat = DateFormat('EEE d MMM yyyy');

final class StepCreated extends ConsumerStatefulWidget {
  const StepCreated({super.key, required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  ConsumerState<StepCreated> createState() => _StepCreatedState();
}

class _StepCreatedState extends ConsumerState<StepCreated> {
  bool _busy = false;

  IntakeDraft get _draft => widget.draft;

  Future<void> _assign() async {
    final designer = await pickCadDesigner(
      context,
      selectedId: _draft.cadAssignee?.id ??
          _draft.rail?.stageFor(LifecycleStage.cad)?.assignedTo,
    );
    if (designer == null || !mounted) return;
    setState(() => _busy = true);
    final failure = await ref.intake(widget.jobKey).assignCadDesigner(designer);
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) {
      showFailure(context, failure);
      return;
    }
    showDone(context, '${designer.fullName} has the CAD stage.');
  }

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: _draft.displayCode));
    if (!mounted) return;
    showDone(context, '${_draft.displayCode} copied. Write it on the job bag.');
  }

  Future<void> _startAnother() async {
    ref.intake(widget.jobKey).startAnother();
    if (!mounted) return;
    // A fresh wizard session, not the committed job's key — otherwise the next job would resume
    // into the one just finished.
    context.go(Paths.newJob);
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    final job = draft.requireJob;

    return WizardScaffold(
      step: IntakeStep.created.number,
      totalSteps: IntakeStep.total,
      title: IntakeStep.created.title,
      subtitle: IntakeStep.created.subtitle,
      trailing: WizardTrailing(draft: draft),
      ctaLabel: 'Open the job order',
      ctaIcon: Icons.open_in_new_rounded,
      busy: _busy,
      onCta: () => context.go(Paths.job(job.id)),
      secondaryLabel: 'Start another',
      onSecondary: _startAnother,
      onClose: () => leaveWizard(context),
      footerNote: 'The specification is locked to this number. Changes from here are recorded '
          'as revisions on the job, not as edits to a draft.',
      children: [
        _Minted(draft: draft, onCopy: _copyCode),
        const Gap.md(),
        _NextStep(draft: draft, busy: _busy, onAssign: _assign),
        const Gap.md(),
        _Rail(draft: draft),
        const Gap.md(),
        _AtAGlance(draft: draft),
      ],
    );
  }
}

// ================================================================= the number

final class _Minted extends StatelessWidget {
  const _Minted({required this.draft, required this.onCopy});

  final IntakeDraft draft;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final job = draft.requireJob;
    final committed = job.committedAt;

    return DhCard(
      accent: context.dh.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.verified_rounded, size: 26, color: context.dh.gold),
              const SizedBox(width: Spacing.sm + Spacing.xs),
              Expanded(
                child: Text(
                  draft.isCommitted ? 'Job order created' : 'Draft saved',
                  style: context.text.headlineSmall
                      ?.copyWith(color: context.scheme.onSurface),
                ),
              ),
            ],
          ),
          const Gap.md(),
          // D-001. The one figure on this screen that has to be readable across a workshop.
          SelectableText(
            draft.displayCode,
            style: AppTheme.mono(
              size: 30,
              weight: FontWeight.w700,
              color: context.scheme.onSurface,
            ),
          ),
          const Gap.sm(),
          Text(
            committed == null
                ? 'Year-scoped, so the sequence resets cleanly in January.'
                : 'Minted ${DateFormat('d MMM yyyy · HH:mm').format(committed.toLocal())}. '
                    'Year-scoped, so the sequence resets cleanly in January.',
            style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const Gap.md(),
          OutlinedButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy the job number'),
          ),
        ],
      ),
    );
  }
}

// ================================================================= next step

final class _NextStep extends StatelessWidget {
  const _NextStep({required this.draft, required this.busy, required this.onAssign});

  final IntakeDraft draft;
  final bool busy;
  final Future<void> Function() onAssign;

  @override
  Widget build(BuildContext context) {
    final cad = draft.rail?.stageFor(LifecycleStage.cad);
    final assignee = draft.cadAssignee;
    final assigned = assignee != null || (cad?.assignedTo != null);

    return DhSectionCard(
      title: 'Next step',
      subtitle: 'The first of the fourteen stages.',
      leading: const Icon(Icons.design_services_outlined),
      accent: assigned ? context.dh.success : context.dh.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DataPair(
                  label: 'Stage',
                  value: LifecycleStage.cad.label,
                  emphasis: DataEmphasis.strong,
                ),
              ),
              StatusChip(
                label: assigned ? 'Assigned' : 'Unassigned',
                tone: assigned ? ChipTone.success : ChipTone.warning,
                dense: true,
                dot: true,
              ),
            ],
          ),
          const Gap.md(),
          if (assignee != null)
            DataPair(
              label: 'With',
              value: assignee.fullName,
              emphasis: DataEmphasis.strong,
              icon: Icons.person_outline_rounded,
            )
          else if (assigned)
            const DataPair(
              label: 'With',
              value: 'Assigned — open the job order to see who.',
            )
          else
            const NoteStrip(
              text: 'An unassigned CAD stage sits in the queue until somebody picks it up. '
                  'Naming a designer now is how it gets started today.',
            ),
          const Gap.md(),
          FilledButton.icon(
            onPressed: busy ? null : () => onAssign(),
            icon: const Icon(Icons.person_add_alt_outlined, size: 18),
            label: Text(assigned ? 'Reassign the CAD' : 'Assign a CAD designer'),
          ),
        ],
      ),
    );
  }
}

// ================================================================= rail

/// D-002, on screen: the 14-stage vocabulary, seeded complete at commit so the timeline reads as
/// a whole pipeline from the first day rather than growing a stage at a time.
final class _Rail extends StatelessWidget {
  const _Rail({required this.draft});

  final IntakeDraft draft;

  @override
  Widget build(BuildContext context) {
    final rail = draft.rail;
    final nodes = rail == null || rail.isEmpty
        ? StageNode.railFor(
            active: LifecycleStage.cad,
            skipped: (draft.acceptance?.skipsCertification ?? false)
                ? const {LifecycleStage.cert}
                : const <LifecycleStage>{},
          )
        : [
            for (final stage in rail.stages)
              StageNode(
                stage: stage.stage,
                state: stage.state,
                isLate: stage.isLate,
                withPartner: stage.isWithPartner,
              ),
          ];

    return DhSectionCard(
      title: 'The rail',
      subtitle: rail == null || !rail.isSeeded
          ? 'Fourteen stages, seeded at commit.'
          : '${rail.settledCount} of 14 settled.',
      leading: const Icon(Icons.route_outlined),
      padding: const EdgeInsets.symmetric(vertical: Spacing.md),
      child: JobStageRail(nodes: nodes),
    );
  }
}

// ================================================================= summary

final class _AtAGlance extends StatelessWidget {
  const _AtAGlance({required this.draft});

  final IntakeDraft draft;

  @override
  Widget build(BuildContext context) {
    final job = draft.requireJob;
    final requested = draft.delivery?.requestedDate ?? job.requestedDelivery;

    return DhSectionCard(
      title: 'At a glance',
      leading: const Icon(Icons.summarize_outlined),
      child: DataPairGrid(
        children: [
          DataPair(
            label: 'Customer',
            value: draft.customer?.name ?? DataPair.placeholder,
          ),
          DataPair(
            label: 'Piece',
            value: draft.category == null
                ? job.displayTitle
                : '${draft.category!.label}'
                    '${draft.subStyle == null ? '' : ' · ${draft.subStyle!.label}'}',
          ),
          DataPair.money(label: 'Value', amount: draft.quoteTotal),
          DataPair.mono(
            label: 'Due',
            value: requested == null
                ? DataPair.placeholder
                : _dayFormat.format(requested),
          ),
          DataPair.custom(
            label: 'Priority',
            child: PriorityChip(draft.priority, dense: true),
          ),
          DataPair.mono(
            label: 'Metal',
            value: draft.metalSpec?.alloyLabel ?? DataPair.placeholder,
          ),
        ],
      ),
    );
  }
}
