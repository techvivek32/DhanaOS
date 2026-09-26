/// Step 8 — delivery.
///
/// `delivery_requirements` drew a date as static text — "Mar 15, 2024" — with no picker, no
/// validation, and no relationship to anything else on the screen. It also leaked its template's
/// origin: one of its blocks still read **"CNC Machining"**, which is not a process this workshop
/// runs. Both are gone. The copy here is jewellery, and the date is a commitment the whole
/// 14-stage rail is planned backwards from.
///
/// The buffers are the substance of this step. The mockup hardcoded two days of dispatch buffer
/// regardless of priority, and its own source carried the comment *"Could adjust buffers here
/// based on priority"*. That comment is implemented: a rush job buys less slack in the plan, not
/// a faster courier. Choosing no certifying lab on step 9 zeroes the certification buffer, which
/// is the other cross-screen dependency the mockups declared and never wired.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

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
import 'package:dhanaos/features/intake/widgets/date_field.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final _dayFormat = DateFormat('EEE d MMM yyyy');

final class StepDelivery extends ConsumerWidget {
  const StepDelivery({super.key, required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.intake(jobKey);
    final job = draft.requireJob;
    final delivery = draft.delivery ??
        DeliveryScheduleEdit.blank(job.id, priority: job.priority);

    return IntakeStepScaffold(
      draft: draft,
      jobKey: jobKey,
      step: IntakeStep.delivery,
      footerNote: 'A date promised here becomes the date the whole rail is scheduled against. '
          'Promise the one the plan actually supports.',
      children: [
        _RequestedDate(draft: draft, controller: controller),
        const Gap.md(),
        _PriorityBlock(draft: draft, delivery: delivery, controller: controller),
        const Gap.md(),
        _Plan(draft: draft),
        const Gap.md(),
        _Buffers(draft: draft, delivery: delivery, controller: controller),
        const Gap.md(),
        _Terms(delivery: delivery, controller: controller),
      ],
    );
  }
}

// ================================================================= the date

final class _RequestedDate extends StatelessWidget {
  const _RequestedDate({required this.draft, required this.controller});

  final IntakeDraft draft;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    final requested = draft.delivery?.requestedDate ?? draft.job?.requestedDelivery;
    final tooSoon = draft.deliveryBeatsLeadTime;

    return DhSectionCard(
      title: 'When the customer needs it',
      subtitle: 'The one date the customer will hold us to.',
      leading: const Icon(Icons.event_outlined),
      accent: tooSoon ? context.scheme.error : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FieldBlock(
            label: 'Requested delivery',
            reqCode: 'REQ-TML-05',
            reqCritical: true,
            child: DateField(
              value: requested,
              // A past date is made impossible rather than merely wrong.
              firstDate: IntakeDraft.today,
              lastDate: IntakeDraft.today.add(const Duration(days: 730)),
              helpText: 'When does the customer need it?',
              emptyLabel: 'No date agreed yet',
              warning: tooSoon
                  ? 'This job needs ${draft.leadDays} days end to end. The earliest honest date '
                      'is ${_dayFormat.format(draft.earliestDelivery)} — move the date, or raise '
                      'the priority below and the plan shortens with it.'
                  : null,
              onChanged: (value) => runIntake(
                context,
                () => controller.editDelivery(requestedDate: Opt(value)),
              ),
              onCleared: () => runIntake(
                context,
                () => controller.editDelivery(
                  requestedDate: const Opt<DateTime>.clear(),
                ),
              ),
            ),
          ),
          if (requested != null && !tooSoon) ...[
            const Gap.md(),
            NoteStrip(
              tone: NoteTone.good,
              icon: Icons.check_circle_outline_rounded,
              text: 'That date works. The piece has to be off the bench by '
                  '${_dayFormat.format(draft.benchTarget ?? draft.earliestDelivery)} to make it.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= priority

final class _PriorityBlock extends StatelessWidget {
  const _PriorityBlock({
    required this.draft,
    required this.delivery,
    required this.controller,
  });

  final IntakeDraft draft;
  final DeliverySchedule delivery;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    return DhSectionCard(
      title: 'Priority',
      subtitle: 'Priority buys bench time, not a faster courier.',
      leading: const Icon(Icons.bolt_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableTileGroup<Priority>(
            values: Priority.values,
            selected: delivery.priority,
            dense: true,
            labelOf: (value) => value.label,
            blurbOf: (value) => switch (value) {
              Priority.standard =>
                '12 bench days. The piece queues behind whatever is in front of it.',
              Priority.rush =>
                '8 bench days. It jumps the CAD and setting queues and costs the shop capacity.',
              Priority.critical =>
                '5 bench days. Everything else moves aside — use it when it is genuinely true.',
            },
            iconOf: (value) => switch (value) {
              Priority.standard => Icons.schedule_outlined,
              Priority.rush => Icons.bolt_rounded,
              Priority.critical => Icons.priority_high_rounded,
            },
            badgeOf: (value) => value == delivery.priority
                ? PriorityChip(value, dense: true)
                : null,
            onChanged: (value) => runIntake(
              context,
              () => controller.editDelivery(priority: value),
            ),
          ),
          if (delivery.priority != Priority.standard) ...[
            const Gap.md(),
            NoteStrip(
              tone: NoteTone.consequence,
              icon: Icons.local_shipping_outlined,
              text: 'The dispatch buffer drops to one day at this priority. That is the plan '
                  'carrying less slack, not the courier going faster — a missed pickup on a '
                  '${delivery.priority.label.toLowerCase()} job has nowhere to absorb the delay.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= the plan

/// Where the days actually go. Nothing on this card is typed in: it is the same arithmetic
/// `IntakeDraft` uses to decide whether the requested date is honest.
final class _Plan extends StatelessWidget {
  const _Plan({required this.draft});

  final IntakeDraft draft;

  @override
  Widget build(BuildContext context) {
    final requested = draft.delivery?.requestedDate ?? draft.job?.requestedDelivery;
    final bench = draft.benchLeadDays;
    final cert = draft.certBufferDays;
    final dispatch = draft.dispatchBufferDays;

    return DhSectionCard(
      title: 'Where the days go',
      subtitle: '${draft.leadDays} days from today at ${draft.priority.label} priority.',
      leading: const Icon(Icons.timeline_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PlanRow(
            label: 'On the bench',
            days: bench,
            detail: 'CAD, approval, wax, casting, assembly, setting, polishing and QC.',
            total: draft.leadDays,
          ),
          const Gap.sm(),
          _PlanRow(
            label: 'At the lab',
            days: cert,
            detail: cert == 0
                ? 'No certifying lab chosen, so no days are reserved. Choose one on step 9 and '
                    'three days come back.'
                : 'Certification turnaround, door to door.',
            total: draft.leadDays,
          ),
          const Gap.sm(),
          _PlanRow(
            label: 'Packing and dispatch',
            days: dispatch,
            detail: 'Final inspection, hallmark check, insured packing and pickup.',
            total: draft.leadDays,
          ),
          const Gap.md(),
          Divider(height: 1, thickness: 1, color: context.dh.outlineVariant),
          const Gap.md(),
          DataPairGrid(
            children: [
              DataPair.mono(
                label: 'Earliest honest date',
                value: _dayFormat.format(draft.earliestDelivery),
                emphasis: DataEmphasis.strong,
              ),
              if (requested != null)
                DataPair.mono(
                  label: 'Off the bench by',
                  value: _dayFormat.format(draft.benchTarget ?? draft.earliestDelivery),
                  emphasis: DataEmphasis.strong,
                  valueColor: draft.deliveryBeatsLeadTime ? context.scheme.error : null,
                ),
              if (requested != null)
                DataPair.mono(
                  label: 'Promised',
                  value: _dayFormat.format(requested),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

final class _PlanRow extends StatelessWidget {
  const _PlanRow({
    required this.label,
    required this.days,
    required this.detail,
    required this.total,
  });

  final String label;
  final int days;
  final String detail;
  final int total;

  @override
  Widget build(BuildContext context) {
    final share = total == 0 ? 0.0 : days / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: context.text.bodyMedium?.copyWith(color: context.scheme.onSurface),
              ),
            ),
            Text(
              days == 1 ? '1 day' : '$days days',
              style: AppTheme.mono(
                size: 13,
                weight: FontWeight.w600,
                color: days == 0
                    ? context.scheme.onSurfaceVariant
                    : context.scheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        ClipRRect(
          borderRadius: Radii.rFull,
          child: LinearProgressIndicator(
            value: share,
            minHeight: 4,
            backgroundColor: context.dh.surfaceContainerHigh,
            valueColor: AlwaysStoppedAnimation(context.scheme.secondary),
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          detail,
          style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

// ================================================================= buffers

final class _Buffers extends StatelessWidget {
  const _Buffers({
    required this.draft,
    required this.delivery,
    required this.controller,
  });

  final IntakeDraft draft;
  final DeliverySchedule delivery;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    final skipsCert = draft.acceptance?.skipsCertification ?? false;

    return DhSectionCard(
      title: 'Buffers',
      subtitle: 'Override the defaults when this particular job needs it.',
      leading: const Icon(Icons.more_time_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StepperField.count(
            value: delivery.dispatchBufferD,
            min: 0,
            max: 21,
            label: 'Dispatch buffer',
            unit: 'd',
            helperText: 'Default at ${delivery.priority.label} priority is '
                '${delivery.recommendedDispatchBuffer()} '
                '${delivery.recommendedDispatchBuffer() == 1 ? 'day' : 'days'}.',
            onChanged: (value) => runIntake(
              context,
              () => controller.editDelivery(
                dispatchBufferD: value,
                delay: SaveDelay.dragging,
              ),
            ),
          ),
          const Gap.md(),
          StepperField.count(
            value: delivery.certBufferD,
            min: 0,
            max: 45,
            label: 'Certification buffer',
            unit: 'd',
            enabled: !skipsCert,
            helperText: skipsCert
                // The cross-screen dependency, made visible rather than silently applied.
                ? 'No certifying lab was chosen on step 9, so the certification stage is '
                    'skipped and this buffer is zero.'
                : 'Door to door at the lab. IGI in Mumbai runs faster than GIA in Antwerp.',
            onChanged: (value) => runIntake(
              context,
              () => controller.editDelivery(
                certBufferD: value,
                delay: SaveDelay.dragging,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================= terms

final class _Terms extends StatelessWidget {
  const _Terms({required this.delivery, required this.controller});

  final DeliverySchedule delivery;
  final IntakeController controller;

  @override
  Widget build(BuildContext context) {
    return DhSectionCard(
      title: 'Delivery terms',
      subtitle: 'What happens if the date slips, and whether part of the order can go early.',
      leading: const Icon(Icons.handshake_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ToggleRow(
            title: 'Hard deadline',
            blurb: 'The date is an anniversary, a wedding or a flight — late is worth nothing. '
                'The job shows as at-risk the moment the plan stops supporting it.',
            icon: Icons.event_busy_outlined,
            value: delivery.hardDeadline,
            onChanged: (value) => runIntake(
              context,
              () => controller.editDelivery(hardDeadline: value),
            ),
          ),
          const Divider(),
          ToggleRow(
            title: 'Partial delivery allowed',
            blurb: 'A pair of earrings can ship one finished piece ahead of the other. Turn it '
                'off and nothing leaves until the whole order is complete.',
            icon: Icons.call_split_outlined,
            value: delivery.partialAllowed,
            onChanged: (value) => runIntake(
              context,
              () => controller.editDelivery(partialAllowed: value),
            ),
          ),
          if (delivery.hardDeadline) ...[
            const Gap.md(),
            const NoteStrip(
              tone: NoteTone.consequence,
              icon: Icons.flag_outlined,
              text: 'A hard deadline changes how the shop floor treats a delay: an exception on '
                  'this job is escalated rather than absorbed into the next day\'s queue.',
            ),
          ],
        ],
      ),
    );
  }
}
