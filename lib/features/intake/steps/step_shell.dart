/// The frame the ten form steps share.
///
/// Every step needs the same five things wired the same way — the step number, the question at the
/// top, the gate under the button, back, and leave. Wiring them per screen is how ten screens end
/// up with nine different gate behaviours, which is exactly what the mockups had: one screen
/// enforced capture, one only changed `opacity` and left the button live, eight had no logic at
/// all.
///
/// So the gate is not a parameter here. It comes from [IntakeDraft.blockReasonFor], and a step
/// cannot opt out of it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
import 'package:dhanaos/features/intake/intake_wizard.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class IntakeStepScaffold extends ConsumerWidget {
  const IntakeStepScaffold({
    super.key,
    required this.draft,
    required this.jobKey,
    required this.step,
    required this.children,
    this.ctaLabel,
    this.onCta,
    this.ctaIcon,
    this.secondaryLabel,
    this.onSecondary,
    this.footerNote,
    this.busy = false,
    this.showBack = true,
  });

  final IntakeDraft draft;
  final String? jobKey;
  final IntakeStep step;
  final List<Widget> children;

  /// Defaults to "Continue to <next step>" — the next step this draft will actually reach, so a
  /// job with no stones does not promise a stone screen.
  final String? ctaLabel;

  /// Defaults to advancing. Steps that have to do something first (commit, send for approval)
  /// pass their own.
  final Future<void> Function()? onCta;
  final IconData? ctaIcon;
  final String? secondaryLabel;
  final Future<void> Function()? onSecondary;
  final String? footerNote;
  final bool busy;
  final bool showBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = draft.blockReasonFor(step);

    return WizardScaffold(
      step: step.number,
      totalSteps: IntakeStep.total,
      title: step.title,
      subtitle: step.subtitle,
      trailing: WizardTrailing(draft: draft),
      ctaLabel: ctaLabel ?? draft.ctaLabelFor(step),
      ctaIcon: ctaIcon ?? Icons.arrow_forward_rounded,
      ctaBlockedReason: blocked,
      busy: busy,
      onCta: () async {
        final action = onCta ?? () => _advance(context, ref);
        await action();
      },
      secondaryLabel: secondaryLabel,
      onSecondary: onSecondary == null ? null : () => onSecondary!(),
      onBack: showBack && draft.previousBefore(step) != null
          ? () => ref.intake(jobKey).back()
          : null,
      onClose: () => leaveWithConfirm(context, ref, jobKey, draft),
      footerNote: footerNote,
      children: children,
    );
  }

  Future<void> _advance(BuildContext context, WidgetRef ref) async {
    final failure = await ref.intake(jobKey).advance();
    if (failure != null && context.mounted) showFailure(context, failure);
  }
}
