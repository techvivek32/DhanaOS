/// The intake wizard — the screen the router points `/jobs/new` and `/jobs/new/step/:n` at.
///
/// It owns three things and delegates everything else:
///   * resolving the draft (loading, failed, ready);
///   * mapping [IntakeStep] to a screen, with the stone step skipped when REQ-GEM-03 says No;
///   * the chrome every step shares — the code chip, the autosave badge, back and leave.
///
/// The steps themselves are eleven small widgets. None of them knows how to save; they call the
/// controller and read the draft back, which is what keeps the gates in one place.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
import 'package:dhanaos/features/intake/steps/step_category.dart';
import 'package:dhanaos/features/intake/steps/step_commercials.dart';
import 'package:dhanaos/features/intake/steps/step_created.dart';
import 'package:dhanaos/features/intake/steps/step_delivery.dart';
import 'package:dhanaos/features/intake/steps/step_design.dart';
import 'package:dhanaos/features/intake/steps/step_job_type.dart';
import 'package:dhanaos/features/intake/steps/step_media.dart';
import 'package:dhanaos/features/intake/steps/step_metal.dart';
import 'package:dhanaos/features/intake/steps/step_quality.dart';
import 'package:dhanaos/features/intake/steps/step_review.dart';
import 'package:dhanaos/features/intake/steps/step_stones.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class IntakeWizard extends ConsumerStatefulWidget {
  const IntakeWizard({super.key, this.step, this.jobId});

  /// From `/jobs/new/step/:n`. A hint, applied once: the draft's own `wizard_step` wins on a
  /// resume, because that is the number the server has.
  final int? step;

  /// Resume a specific draft. `/jobs/new` passes nothing and opens a fresh wizard session.
  final String? jobId;

  @override
  ConsumerState<IntakeWizard> createState() => _IntakeWizardState();
}

class _IntakeWizardState extends ConsumerState<IntakeWizard> {
  bool _routeStepApplied = false;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(intakeControllerProvider(widget.jobId));

    return async.when(
      loading: () => const _WizardLoading(),
      error: (error, _) => _WizardError(
        failure: error,
        onRetry: () => ref.invalidate(intakeControllerProvider(widget.jobId)),
      ),
      data: (draft) {
        _applyRouteStep(draft);
        return _WizardBody(draft: draft, jobKey: widget.jobId);
      },
    );
  }

  /// The path parameter only gets one chance, and only once a draft actually exists. Deep-linking
  /// to step 7 with nothing captured would otherwise drop an operator into a pricing screen for a
  /// job that has no product.
  void _applyRouteStep(IntakeDraft draft) {
    if (_routeStepApplied) return;
    _routeStepApplied = true;
    final requested = widget.step;
    if (requested == null || draft.job == null) return;
    final target = IntakeStep.fromNumber(requested);
    if (target == draft.step || draft.isSkipped(target)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.intake(widget.jobId).goTo(target);
    });
  }
}

final class _WizardBody extends ConsumerWidget {
  const _WizardBody({required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Steps 2-11 all read `draft.requireJob`. Without a draft row there is nothing to read, so
    // the wizard stands on step 1 whatever the URL or a stale `wizard_step` says.
    final step = draft.job == null ? IntakeStep.jobType : draft.step;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack(context, ref, step);
      },
      child: switch (step) {
        IntakeStep.jobType => StepJobType(draft: draft, jobKey: jobKey),
        IntakeStep.media => StepMedia(draft: draft, jobKey: jobKey),
        IntakeStep.category => StepCategory(draft: draft, jobKey: jobKey),
        IntakeStep.design => StepDesign(draft: draft, jobKey: jobKey),
        IntakeStep.metal => StepMetal(draft: draft, jobKey: jobKey),
        IntakeStep.stones => StepStones(draft: draft, jobKey: jobKey),
        IntakeStep.commercials => StepCommercials(draft: draft, jobKey: jobKey),
        IntakeStep.delivery => StepDelivery(draft: draft, jobKey: jobKey),
        IntakeStep.quality => StepQuality(draft: draft, jobKey: jobKey),
        IntakeStep.review => StepReview(draft: draft, jobKey: jobKey),
        IntakeStep.created => StepCreated(draft: draft, jobKey: jobKey),
      },
    );
  }

  Future<void> _handleBack(BuildContext context, WidgetRef ref, IntakeStep step) async {
    if (step == IntakeStep.created) {
      leaveWizard(context);
      return;
    }
    if (step == IntakeStep.jobType) {
      await leaveWithConfirm(context, ref, jobKey, draft);
      return;
    }
    await ref.intake(jobKey).back();
  }
}

/// Chrome every form step wears: the code chip and the autosave badge.
final class WizardTrailing extends StatelessWidget {
  const WizardTrailing({super.key, required this.draft});

  final IntakeDraft draft;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        StatusChip.code(
          draft.displayCode,
          dense: true,
          tone: draft.isCommitted ? ChipTone.success : ChipTone.neutral,
        ),
        const SizedBox(height: Spacing.xs),
        SaveBadge(draft: draft),
      ],
    );
  }
}

/// "Saved 14:32" / "Saving…" / "Not saved". The wizard writes on every field change, so the
/// operator is owed a visible answer to "is it safe to walk away".
final class SaveBadge extends ConsumerWidget {
  const SaveBadge({super.key, required this.draft, this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final dh = context.dh;

    final (IconData icon, String text, Color colour) = switch (draft.save) {
      SaveState.idle => (
          Icons.cloud_queue_rounded,
          draft.hasJob ? 'Draft open' : 'Not started',
          scheme.onSurfaceVariant,
        ),
      SaveState.saving => (Icons.sync_rounded, 'Saving…', scheme.onSurfaceVariant),
      SaveState.saved => (
          Icons.cloud_done_rounded,
          draft.savedAt == null ? 'Saved' : 'Saved ${_clock(draft.savedAt!)}',
          dh.success,
        ),
      SaveState.failed => (Icons.cloud_off_rounded, 'Not saved', scheme.error),
    };

    final badge = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: colour),
        const SizedBox(width: Spacing.xs),
        Text(text, style: AppTheme.mono(size: 10.5, color: colour)),
      ],
    );

    if (draft.save != SaveState.failed) return badge;

    return Tooltip(
      message: draft.saveError ?? 'The last change did not reach the server.',
      child: InkWell(
        borderRadius: Radii.rSm,
        onTap: () async {
          final failure = await ref.intake(jobKey).retrySave();
          if (!context.mounted) return;
          if (failure == null) {
            showDone(context, 'Everything on this job order is saved.');
          } else {
            showFailure(context, failure);
          }
        },
        child: badge,
      ),
    );
  }

  static String _clock(DateTime at) {
    final local = at.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

/// Leave the wizard. The draft is kept — abandoning it is a separate, confirmed action.
void leaveWizard(BuildContext context) => context.go(Paths.jobs);

/// The X in the header. Offers the two honest options rather than silently keeping a half-filled
/// job in the list forever.
Future<void> leaveWithConfirm(
  BuildContext context,
  WidgetRef ref,
  String? jobKey,
  IntakeDraft draft,
) async {
  if (!draft.hasJob) {
    leaveWizard(context);
    return;
  }
  final discard = await confirmAction(
    context,
    title: 'Leave ${draft.displayCode}?',
    message: 'Everything captured so far is already saved. Keep the draft and it waits in the '
        'job list at step ${draft.step.number}. Abandon it and it is cancelled with a reason on '
        'the record — nothing is deleted.',
    confirmLabel: 'Abandon the draft',
    cancelLabel: 'Keep it and leave',
  );
  if (!context.mounted) return;
  if (discard) {
    final failure = await ref.intake(jobKey).discardDraft();
    if (!context.mounted) return;
    if (failure != null) {
      showFailure(context, failure);
      return;
    }
  }
  if (!context.mounted) return;
  leaveWizard(context);
}

final class _WizardLoading extends StatelessWidget {
  const _WizardLoading();

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: context.scheme.surface,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: const [
                LoadingSkeleton(height: 18, width: 160),
                SizedBox(height: Spacing.lg),
                LoadingSkeleton.card(),
                SizedBox(height: Spacing.md),
                LoadingSkeleton.card(),
                SizedBox(height: Spacing.md),
                LoadingSkeleton.lines(count: 4),
              ],
            ),
          ),
        ),
      );
}

final class _WizardError extends StatelessWidget {
  const _WizardError({required this.failure, required this.onRetry});

  final Object failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = failure is DhFailure
        ? (failure as DhFailure).message
        : 'DhanaOS could not open the job draft.';
    return Scaffold(
      backgroundColor: context.scheme.surface,
      body: SafeArea(
        child: ErrorState(
          title: 'The draft did not open',
          message: message,
          detail: failure is DhFailure ? (failure as DhFailure).detail : failure.toString(),
          onRetry: onRetry,
          retryLabel: 'Try again',
          secondaryLabel: 'Back to jobs',
          onSecondary: () => leaveWizard(context),
        ),
      ),
    );
  }
}
