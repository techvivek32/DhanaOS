/// Step 10 — review the job order.
///
/// D-012 takes `review_job_order` as the base and the summary-card idiom from `confirm_order`.
/// What neither had was anything behind them: `review_job_order` showed three approval gates, all
/// reading "Pending", with **no screen behind any of them** and no way to decide one; every figure
/// on `confirm_order` was static text.
///
/// So this step does three things the mockups did not:
///
///  * **It reports what is unfinished, by step, with a way to get there.** Nine steps of capture
///    and a dead Continue button is not a review screen.
///  * **The totals are derived.** Every money figure here is computed from the quote's own lines
///    and the server's recalculated totals, not transcribed.
///  * **The gates are real.** They are opened by a write, decided by whoever holds the role, and
///    a rejection owes a reason — the same asymmetry D-011 rule 2 applies to a CAD rejection.
///    `fn_commit_job` refuses to mint a code while any of them is unapproved, so the button here
///    is the polite half of a rule Postgres enforces.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
import 'package:dhanaos/features/intake/intake_wizard.dart';
import 'package:dhanaos/features/intake/steps/step_shell.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final _dayFormat = DateFormat('EEE d MMM yyyy');

final class StepReview extends ConsumerStatefulWidget {
  const StepReview({super.key, required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  ConsumerState<StepReview> createState() => _StepReviewState();
}

class _StepReviewState extends ConsumerState<StepReview> {
  bool _busy = false;

  IntakeDraft get _draft => widget.draft;
  IntakeController get _controller => ref.intake(widget.jobKey);

  Future<void> _run(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final failure = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) showFailure(context, failure);
  }

  /// Phase one: open the three gate rows. Until they exist there is nothing for anybody to
  /// approve, which is why the absence of gates is not itself a block (see `_reviewGates`).
  Future<void> _sendForApproval() => _run(() async {
        final failure = await _controller.sendForApproval();
        if (failure == null && mounted) {
          showDone(
            context,
            'Sent. Three approvals are now on the record and waiting for their holders.',
          );
        }
        return failure;
      });

  /// Phase two: mint the D-001 code. Irreversible — the draft code is replaced, the 14-stage
  /// rail is seeded and the audit trail opens.
  Future<void> _commit() async {
    final confirmed = await confirmAction(
      context,
      title: 'Create the job order?',
      message: 'A job number is minted, the 14-stage rail is seeded, and the specification '
          'becomes what the bench is building against. The draft code '
          '${_draft.displayCode} is replaced and the job appears on the shop floor.',
      confirmLabel: 'Create the job order',
      cancelLabel: 'Not yet',
      destructive: false,
    );
    if (!confirmed || !mounted) return;
    await _run(_controller.commit);
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    final readyToCommit = draft.gates.isNotEmpty;

    return IntakeStepScaffold(
      draft: draft,
      jobKey: widget.jobKey,
      step: IntakeStep.review,
      busy: _busy,
      ctaIcon: readyToCommit ? Icons.verified_outlined : Icons.send_rounded,
      onCta: readyToCommit ? _commit : _sendForApproval,
      secondaryLabel: 'Save draft',
      onSecondary: () async => leaveWizard(context),
      footerNote: readyToCommit
          ? 'The job number is minted server-side so two devices cannot claim the same one.'
          : 'Nothing is committed yet. Sending for approval opens the three gates; the job '
              'number comes after they clear.',
      children: [
        _Completeness(draft: draft, jobKey: widget.jobKey),
        const Gap.md(),
        _Gates(draft: draft, controller: _controller, busy: _busy),
        const Gap.md(),
        _JobHeader(draft: draft, jobKey: widget.jobKey),
        const Gap.md(),
        _References(draft: draft, jobKey: widget.jobKey),
        const Gap.md(),
        _Design(draft: draft, jobKey: widget.jobKey),
        const Gap.md(),
        _Metal(draft: draft, jobKey: widget.jobKey),
        if (!draft.skipsStones) ...[
          const Gap.md(),
          _Stones(draft: draft, jobKey: widget.jobKey),
        ],
        const Gap.md(),
        _Commercials(draft: draft, jobKey: widget.jobKey),
        const Gap.md(),
        _Delivery(draft: draft, jobKey: widget.jobKey),
        const Gap.md(),
        _Quality(draft: draft, jobKey: widget.jobKey),
      ],
    );
  }
}

// ================================================================= shared frame

/// A read-only block with a way back to the step that owns it. The jump matters: a review screen
/// that reports a gap and makes the operator navigate to it by hand is a review screen nobody
/// finishes.
final class _SummaryCard extends ConsumerWidget {
  const _SummaryCard({
    required this.title,
    required this.icon,
    required this.step,
    required this.jobKey,
    required this.child,
    this.subtitle,
    this.accent,
  });

  final String title;
  final IconData icon;
  final IntakeStep step;
  final String? jobKey;
  final Widget child;
  final String? subtitle;
  final Color? accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DhSectionCard(
      title: title,
      subtitle: subtitle,
      leading: Icon(icon),
      accent: accent,
      action: TextButton(
        onPressed: () => ref.intake(jobKey).goTo(step),
        child: Text('Edit step ${step.number}'),
      ),
      child: child,
    );
  }
}

String _orDash(String? value) {
  final v = value?.trim();
  return v == null || v.isEmpty ? DataPair.placeholder : v;
}

// ================================================================= completeness

final class _Completeness extends ConsumerWidget {
  const _Completeness({required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = draft.incompleteSteps;
    final done = open.isEmpty;

    return DhSectionCard(
      title: done ? 'Everything is captured' : 'Still to finish',
      subtitle: done
          ? 'All nine capture steps are complete. The job order is ready to go for approval.'
          : '${open.length} step${open.length == 1 ? '' : 's'} of the nine still need '
              'something before this job order can be sent.',
      leading: Icon(done ? Icons.task_alt_rounded : Icons.pending_actions_outlined),
      accent: done ? context.dh.success : context.dh.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: Radii.rFull,
            child: LinearProgressIndicator(
              value: draft.completeness,
              minHeight: 6,
              backgroundColor: context.dh.surfaceContainerHigh,
              valueColor: AlwaysStoppedAnimation(
                done ? context.dh.success : context.dh.gold,
              ),
            ),
          ),
          const Gap.sm(),
          Text(
            '${(draft.completeness * 100).round()}% complete',
            style: AppTheme.mono(size: 12, color: context.scheme.onSurfaceVariant),
          ),
          if (!done) ...[
            const Gap.md(),
            for (final step in open)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: SelectableTile(
                  dense: true,
                  icon: step.icon,
                  title: 'Step ${step.number} · ${step.shortLabel}',
                  blurb: draft.blockReasonFor(step),
                  onTap: () => ref.intake(jobKey).goTo(step),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= approval gates

final class _Gates extends ConsumerWidget {
  const _Gates({required this.draft, required this.controller, required this.busy});

  final IntakeDraft draft;
  final IntakeController controller;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserProvider).value;

    if (draft.gates.isEmpty) {
      return DhSectionCard(
        title: 'Approvals',
        subtitle: 'Three gates clear before a job number is minted.',
        leading: const Icon(Icons.how_to_reg_outlined),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final kind in ApprovalGateKind.values)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: Row(
                  children: [
                    Icon(
                      Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: context.scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        kind.label,
                        style: context.text.bodyMedium
                            ?.copyWith(color: context.scheme.onSurface),
                      ),
                    ),
                    Text(
                      kind.decidingRole.label,
                      style: AppTheme.mono(
                        size: 11,
                        color: context.scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            const NoteStrip(
              text: 'Not opened yet. "Send for Approval" writes these three rows and puts each '
                  'one in front of the role that decides it.',
            ),
          ],
        ),
      );
    }

    final approved = draft.gates.where((g) => g.isApproved).length;

    return DhSectionCard(
      title: 'Approvals',
      subtitle: '$approved of ${draft.gates.length} cleared.',
      leading: const Icon(Icons.how_to_reg_outlined),
      accent: draft.allGatesApproved
          ? context.dh.success
          : (draft.rejectedGates.isNotEmpty ? context.scheme.error : context.dh.gold),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final gate in draft.gates)
            _GateRow(
              gate: gate,
              controller: controller,
              busy: busy,
              // D-008: the UI hides a control the session cannot use; RLS is what refuses the
              // write. An admin can always decide, which is what unblocks a small workshop.
              canDecide: me != null &&
                  me.isInternal &&
                  (me.isAdmin || me.hasRole(gate.decidingRole)),
            ),
        ],
      ),
    );
  }
}

final class _GateRow extends StatelessWidget {
  const _GateRow({
    required this.gate,
    required this.controller,
    required this.busy,
    required this.canDecide,
  });

  final ApprovalGate gate;
  final IntakeController controller;
  final bool busy;
  final bool canDecide;

  @override
  Widget build(BuildContext context) {
    final tone = switch (gate.state) {
      ApprovalGateState.pending => ChipTone.warning,
      ApprovalGateState.approved => ChipTone.success,
      ApprovalGateState.rejected => ChipTone.danger,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: DhCard(
        tone: DhCardTone.inset,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        gate.kind.label,
                        style: context.text.bodyLarge?.copyWith(
                          color: context.scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Decided by ${gate.decidingRole.label}',
                        style: context.text.bodySmall
                            ?.copyWith(color: context.scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                StatusChip(label: gate.state.label, tone: tone, dense: true),
              ],
            ),
            if (gate.note?.trim().isNotEmpty ?? false) ...[
              const Gap.sm(),
              Text(
                gate.note!.trim(),
                style: context.text.bodySmall
                    ?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
            ],
            if (gate.decidedAt != null) ...[
              const Gap.sm(),
              Text(
                DateFormat('d MMM yyyy · HH:mm').format(gate.decidedAt!.toLocal()),
                style: AppTheme.mono(size: 11, color: context.scheme.onSurfaceVariant),
              ),
            ],
            if (gate.isPending) ...[
              const Gap.sm(),
              if (!canDecide)
                NoteStrip(
                  text: 'Only ${gate.decidingRole.label} can clear this one. It is waiting for '
                      'them, not for you.',
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: busy ? null : () => _reject(context),
                        child: const Text('Reject'),
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: FilledButton(
                        onPressed: busy ? null : () => _approve(context),
                        child: const Text('Approve'),
                      ),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _approve(BuildContext context) => runIntake(
        context,
        () => controller.decideGate(
          gate: gate,
          decision: ApprovalGateState.approved,
        ),
      );

  /// D-011 rule 2, applied here: a rejection owes a reason; an approval does not. The button is
  /// dead until something is typed, and it says so.
  Future<void> _reject(BuildContext context) async {
    final note = await _askForReason(context, gate);
    if (note == null || !context.mounted) return;
    await runIntake(
      context,
      () => controller.decideGate(
        gate: gate,
        decision: ApprovalGateState.rejected,
        note: note,
      ),
    );
  }
}

Future<String?> _askForReason(BuildContext context, ApprovalGate gate) =>
    showDialog<String>(
      context: context,
      builder: (dialogContext) => _RejectionDialog(gate: gate),
    );

/// The reason box. A `StatefulWidget` rather than a `StatefulBuilder` so the controller is
/// disposed with the dialog instead of outliving it.
final class _RejectionDialog extends StatefulWidget {
  const _RejectionDialog({required this.gate});

  final ApprovalGate gate;

  @override
  State<_RejectionDialog> createState() => _RejectionDialogState();
}

class _RejectionDialogState extends State<_RejectionDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filled = _reason.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text('Reject ${widget.gate.kind.label.toLowerCase()}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Say what has to change. Whoever picks this job up next reads this sentence and '
            'nothing else.',
            style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const Gap.md(),
          TextField(
            controller: _reason,
            autofocus: true,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'The metal cost is against last month\'s rate. Reprice and resend.',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: context.scheme.error,
            foregroundColor: context.scheme.onError,
          ),
          // D-011 rule 2: the button is dead until a reason exists, the same way the CAD
          // review's "Request Revisions" is.
          onPressed: filled ? () => Navigator.of(context).pop(_reason.text.trim()) : null,
          child: const Text('Reject with this reason'),
        ),
      ],
    );
  }
}

// ================================================================= job header

final class _JobHeader extends StatelessWidget {
  const _JobHeader({required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context) {
    final job = draft.requireJob;
    return _SummaryCard(
      title: 'Job order',
      icon: Icons.badge_outlined,
      step: IntakeStep.media,
      jobKey: jobKey,
      child: DataPairGrid(
        children: [
          DataPair.mono(
            label: 'Reference',
            value: draft.displayCode,
            emphasis: DataEmphasis.strong,
          ),
          DataPair(label: 'Title', value: _orDash(job.title)),
          DataPair(label: 'Customer', value: _orDash(draft.customer?.displayName)),
          DataPair(label: 'Work', value: job.jobType?.label ?? DataPair.placeholder),
          DataPair.mono(label: 'Quantity', value: '${job.quantity}'),
          DataPair.mono(label: 'Currency', value: job.currency),
          DataPair.custom(
            label: 'Priority',
            child: PriorityChip(draft.priority, dense: true),
          ),
        ],
      ),
    );
  }
}

// ================================================================= references

final class _References extends StatelessWidget {
  const _References({required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context) {
    final capture = draft.capture;
    return _SummaryCard(
      title: 'References',
      icon: Icons.photo_camera_outlined,
      step: IntakeStep.media,
      jobKey: jobKey,
      subtitle: capture.evidenceLabel,
      accent: capture.isSatisfied ? null : context.dh.gold,
      child: capture.isSatisfied
          ? DataPairGrid(
              children: [
                DataPair.mono(label: 'Photos', value: '${capture.photos.length}'),
                DataPair.mono(label: 'Voice notes', value: '${capture.voiceNotes.length}'),
                DataPair.mono(label: 'Files', value: '${capture.files.length}'),
                DataPair.mono(
                  label: 'Filed as references',
                  value: '${capture.references.where((r) => r.hasFile).length}',
                ),
              ],
            )
          : const NoteStrip(
              tone: NoteTone.consequence,
              text: 'Nothing captured. The CAD designer would be drawing from a description '
                  'nobody wrote down.',
            ),
    );
  }
}

// ================================================================= design

final class _Design extends StatelessWidget {
  const _Design({required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context) {
    final spec = draft.productSpec;
    final category = draft.category;

    return _SummaryCard(
      title: 'Design',
      icon: Icons.architecture_outlined,
      step: IntakeStep.design,
      jobKey: jobKey,
      subtitle: category == null
          ? null
          : '${category.label}${draft.subStyle == null ? '' : ' · ${draft.subStyle!.label}'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DataPairGrid(
            children: [
              DataPair(label: 'Setting', value: spec?.settingLabel ?? DataPair.placeholder),
              DataPair(
                label: 'Finish',
                value: spec?.metalFinish?.label ?? DataPair.placeholder,
              ),
              DataPair(
                label: 'Band profile',
                value: spec?.bandProfile?.label ?? DataPair.placeholder,
              ),
              DataPair(label: 'Fit', value: spec?.fit?.label ?? DataPair.placeholder),
              DataPair(
                label: 'Side stones',
                value: spec?.sideStones?.label ?? DataPair.placeholder,
              ),
              DataPair.mono(
                label: category == null
                    ? 'Dimensions'
                    : (category.usesRingSize ? 'Ring size' : 'Dimensions'),
                value: (spec == null || category == null)
                    ? DataPair.placeholder
                    : spec.dimensionLabel(category),
                emphasis: DataEmphasis.strong,
              ),
            ],
          ),
          if (spec?.designIntent != null) ...[
            const Gap.md(),
            DataPair(
              label: 'What matters most',
              value: spec!.designIntent == DesignIntent.other
                  ? _orDash(spec.designIntentNote)
                  : spec.designIntent!.label,
            ),
          ],
          if (spec?.notes?.trim().isNotEmpty ?? false) ...[
            const Gap.md(),
            DataPair(label: 'Design notes', value: spec!.notes!.trim(), maxLines: 6),
          ],
        ],
      ),
    );
  }
}

// ================================================================= metal

final class _Metal extends StatelessWidget {
  const _Metal({required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context) {
    final metal = draft.metalSpec;
    return _SummaryCard(
      title: 'Metal',
      icon: Icons.layers_outlined,
      step: IntakeStep.metal,
      jobKey: jobKey,
      subtitle: metal?.alloyLabel,
      accent: (metal != null && !metal.purityIsValid) ? context.scheme.error : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DataPairGrid(
            children: [
              DataPair.mono(
                label: 'Alloy',
                value: metal?.alloyLabel ?? DataPair.placeholder,
                emphasis: DataEmphasis.strong,
              ),
              DataPair.mono(
                label: 'Target weight',
                value: metal?.weightLabel ?? DataPair.placeholder,
                emphasis: DataEmphasis.strong,
              ),
              DataPair.mono(
                label: 'Hallmark',
                value: _orDash(metal?.hallmark),
              ),
              DataPair.mono(
                label: 'Budget band',
                value: metal?.budgetLabel(draft.currency) ?? DataPair.placeholder,
              ),
              DataPair.custom(
                label: 'Stones',
                child: StatusChip(
                  label: switch (metal?.gemstoneInset) {
                    null => 'Not answered',
                    true => 'Set with stones',
                    false => 'Plain metal',
                  },
                  tone: metal?.gemstoneInset == null ? ChipTone.warning : ChipTone.neutral,
                  dense: true,
                ),
              ),
              if (metal?.customerSupplied ?? false)
                const DataPair.custom(
                  label: 'Metal supplied by',
                  child: StatusChip(
                    label: 'Client',
                    tone: ChipTone.warning,
                    dense: true,
                    icon: Icons.shield_outlined,
                  ),
                ),
            ],
          ),
          if (metal?.alloyNotes?.trim().isNotEmpty ?? false) ...[
            const Gap.md(),
            DataPair(label: 'Alloy notes', value: metal!.alloyNotes!.trim(), maxLines: 5),
          ],
        ],
      ),
    );
  }
}

// ================================================================= stones

final class _Stones extends StatelessWidget {
  const _Stones({required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context) {
    final custody = draft.custodyStones;
    var declared = draft.zero;
    for (final stone in custody) {
      declared += stone.declaredValue(draft.currency) ?? draft.zero;
    }

    return _SummaryCard(
      title: 'Stones',
      icon: Icons.diamond_outlined,
      step: IntakeStep.stones,
      jobKey: jobKey,
      subtitle: '${draft.stones.length} specified · ${draft.melee.length} melee parcel'
          '${draft.melee.length == 1 ? '' : 's'} · '
          '${draft.totalCarat.toStringAsFixed(2)} ct total',
      accent: draft.stoneGaps.isEmpty ? null : context.dh.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (draft.stones.isEmpty && draft.melee.isEmpty)
            const NoteStrip(text: 'No stones recorded on this job order.')
          else ...[
            for (final stone in draft.stones)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            stone.displayTitle,
                            style: context.text.bodyMedium
                                ?.copyWith(color: context.scheme.onSurface),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            stone.gradeSummary,
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
                        // The field every redesign dropped, printed on the summary the customer
                        // and the certifier both read.
                        if (stone.origin != null)
                          StatusChip.origin(stone.origin!, dense: true)
                        else
                          const StatusChip(
                            label: 'Origin missing',
                            tone: ChipTone.warning,
                            dense: true,
                          ),
                        const SizedBox(height: Spacing.xs),
                        StatusChip(
                          label: stone.sourcing.label,
                          dense: true,
                          tone: stone.isCustomerSupplied
                              ? ChipTone.warning
                              : ChipTone.neutral,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            for (final parcel in draft.melee)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${parcel.stoneType.label} melee · ${parcel.shape.label}',
                        style: context.text.bodyMedium
                            ?.copyWith(color: context.scheme.onSurface),
                      ),
                    ),
                    Text(
                      parcel.summary,
                      style: AppTheme.mono(
                        size: 11.5,
                        color: context.scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (custody.isNotEmpty) ...[
            const Gap.md(),
            NoteStrip(
              tone: NoteTone.consequence,
              icon: Icons.shield_outlined,
              text: 'The workshop is holding ${custody.length} client-owned '
                  'stone${custody.length == 1 ? '' : 's'} declared at '
                  '${declared.format()}. That figure is on the insurance schedule, not on the '
                  'invoice.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= commercials

final class _Commercials extends StatelessWidget {
  const _Commercials({required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context) {
    final quote = draft.quote;
    final gst = draft.gst;
    final byCategory = draft.costByCategory;

    return _SummaryCard(
      title: 'Pricing',
      icon: Icons.request_quote_outlined,
      step: IntakeStep.commercials,
      jobKey: jobKey,
      subtitle: quote == null
          ? 'No quote on this job yet.'
          : '${quote.basis.label} · ${quote.lines.length} line'
              '${quote.lines.length == 1 ? '' : 's'}',
      accent: draft.isOverEnvelope ? context.scheme.error : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // D-003: the five headings, every time, so the customer's copy and the review agree.
          for (final category in CostCategory.values)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.xs + 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      category.label,
                      style: context.text.bodyMedium
                          ?.copyWith(color: context.scheme.onSurfaceVariant),
                    ),
                  ),
                  Text(
                    (byCategory[category] ?? draft.zero).format(),
                    style: AppTheme.mono(size: 13, color: context.scheme.onSurface),
                  ),
                ],
              ),
            ),
          const Gap.sm(),
          Divider(height: 1, thickness: 1, color: context.dh.outlineVariant),
          const Gap.md(),
          DataPairGrid(
            children: [
              DataPair.money(label: 'Subtotal', amount: draft.quoteSubtotal),
              DataPair.money(label: 'Tax', amount: draft.quoteTax),
              DataPair.money(
                label: 'Grand total',
                amount: draft.quoteTotal,
                emphasis: DataEmphasis.display,
                valueColor: draft.isOverEnvelope ? context.scheme.error : null,
              ),
              if (draft.costCeiling != null)
                DataPair.money(label: 'Ceiling', amount: draft.costCeiling!),
            ],
          ),
          if (gst != null) ...[
            const Gap.md(),
            Text(
              gst.headingLabel,
              style: AppTheme.mono(size: 11.5, color: context.scheme.onSurfaceVariant),
            ),
          ],
          if (draft.isOverEnvelope) ...[
            const Gap.md(),
            const NoteStrip(
              tone: NoteTone.risk,
              icon: Icons.trending_up_rounded,
              text: 'This quote is over the approved ceiling. The Cost Analysis gate is where '
                  'that gets settled — do not send it without a word to whoever approves it.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= delivery

final class _Delivery extends StatelessWidget {
  const _Delivery({required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context) {
    final requested = draft.delivery?.requestedDate ?? draft.job?.requestedDelivery;
    final bench = draft.benchTarget;

    return _SummaryCard(
      title: 'Delivery',
      icon: Icons.local_shipping_outlined,
      step: IntakeStep.delivery,
      jobKey: jobKey,
      subtitle: '${draft.leadDays} day plan at ${draft.priority.label} priority',
      accent: draft.deliveryBeatsLeadTime ? context.scheme.error : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DataPairGrid(
            children: [
              DataPair.mono(
                label: 'Promised',
                value: requested == null
                    ? DataPair.placeholder
                    : _dayFormat.format(requested),
                emphasis: DataEmphasis.strong,
                valueColor: draft.deliveryBeatsLeadTime ? context.scheme.error : null,
              ),
              DataPair.mono(
                label: 'Off the bench by',
                value: bench == null ? DataPair.placeholder : _dayFormat.format(bench),
              ),
              DataPair.mono(
                label: 'Buffers',
                value: '${draft.certBufferDays}d lab · ${draft.dispatchBufferDays}d dispatch',
              ),
              DataPair.custom(
                label: 'Terms',
                child: Wrap(
                  spacing: Spacing.xs,
                  runSpacing: Spacing.xs,
                  children: [
                    if (draft.delivery?.hardDeadline ?? false)
                      const StatusChip(
                        label: 'Hard deadline',
                        tone: ChipTone.danger,
                        dense: true,
                      ),
                    if (draft.delivery?.partialAllowed ?? true)
                      const StatusChip(label: 'Partial allowed', dense: true)
                    else
                      const StatusChip(label: 'Ship complete only', dense: true),
                  ],
                ),
              ),
            ],
          ),
          if (draft.deliveryBeatsLeadTime) ...[
            const Gap.md(),
            NoteStrip(
              tone: NoteTone.risk,
              text: 'The promised date is inside the ${draft.leadDays} days this job needs. '
                  'Earliest honest date is ${_dayFormat.format(draft.earliestDelivery)}.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= quality

final class _Quality extends StatelessWidget {
  const _Quality({required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context) {
    final acceptance = draft.acceptance;

    return _SummaryCard(
      title: 'Quality acceptance',
      icon: Icons.fact_check_outlined,
      step: IntakeStep.quality,
      jobKey: jobKey,
      subtitle: acceptance?.summary,
      child: acceptance == null
          ? const NoteStrip(text: 'Nothing agreed yet — QC would have no list to work from.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in acceptance.checklistLabels)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.xs + 2),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_box_outline_blank_rounded,
                          size: 16,
                          color: context.scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: Text(
                            item,
                            style: context.text.bodySmall
                                ?.copyWith(color: context.scheme.onSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
                const Gap.md(),
                DataPairGrid(
                  children: [
                    DataPair(label: 'Lab', value: acceptance.certLabLabel),
                    DataPair(label: 'Signed off by', value: acceptance.authority.label),
                    DataPair.mono(
                      label: 'Tolerance',
                      value: '± ${acceptance.effectiveToleranceMm.toStringAsFixed(3)} mm',
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
