/// The frame every intake step sits in: a sticky header carrying step progress, a scrolling body,
/// and a sticky footer CTA that can be disabled **with a stated reason**.
///
/// The gate pattern is the whole point. D-011 rule 4 says intake cannot advance past media capture
/// without a reference, and the mockup enforced it by simply greying the button out — an operator
/// staring at a dead "Continue" with nothing telling them why. Worse, the shipping screen's gate
/// only changed `opacity`: it never set `.disabled`, so the button stayed clickable while looking
/// unavailable. Both failures are designed out here:
///
///  * [ctaBlockedReason] is required reading, not a tooltip afterthought — it renders as a visible
///    strip above the button, because a long-press tooltip is undiscoverable on a touch device.
///  * A blocked CTA has `onPressed: null`. There is no path through this widget that paints a
///    button as disabled while leaving it live.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/shared/widgets/reduced_motion.dart';

final class WizardScaffold extends StatelessWidget {
  const WizardScaffold({
    super.key,
    required this.step,
    required this.totalSteps,
    required this.title,
    required this.children,
    required this.ctaLabel,
    this.onCta,
    this.ctaBlockedReason,
    this.ctaIcon,
    this.subtitle,
    this.secondaryLabel,
    this.onSecondary,
    this.onBack,
    this.onClose,
    this.trailing,
    this.footerNote,
    this.busy = false,
    this.bodyPadding = const EdgeInsets.fromLTRB(
      Spacing.md,
      Spacing.md,
      Spacing.md,
      Spacing.xl,
    ),
    this.scrollController,
  }) : assert(step >= 1 && step <= totalSteps, 'step is 1-based and within totalSteps');

  /// 1-based position in the wizard.
  final int step;
  final int totalSteps;

  /// The question this step asks, in the operator's words — "What are we making?", not
  /// "Product Category".
  final String title;

  /// One clarifying line under the title. Optional, and better empty than padded.
  final String? subtitle;

  final List<Widget> children;

  /// What the button *does*: "Continue to Metal", "Commit Job Order". Never "Next".
  final String ctaLabel;

  /// Null disables the CTA. Pair it with [ctaBlockedReason] whenever the reason is a gate rather
  /// than an in-flight request.
  final VoidCallback? onCta;

  /// Why the operator cannot continue, and what would fix it. Setting this disables the CTA even
  /// if [onCta] is non-null, so a gate cannot be half-applied.
  final String? ctaBlockedReason;

  final IconData? ctaIcon;

  /// A left-hand escape: "Save Draft", "Skip Stones".
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  final VoidCallback? onBack;

  /// Abandons the wizard. Renders as an X in the header.
  final VoidCallback? onClose;

  /// Extra header affordance, right of the title — a job-code chip, a help button.
  final Widget? trailing;

  /// Small print under the footer buttons — "You can change this until the CAD is approved."
  final String? footerNote;

  /// Shows a spinner in the CTA and blocks it. For a request in flight, not for a gate.
  final bool busy;

  final EdgeInsetsGeometry bodyPadding;
  final ScrollController? scrollController;

  bool get _ctaEnabled => onCta != null && ctaBlockedReason == null && !busy;

  /// Reduces a set of step requirements to the first unmet one, in the order written. Feed the
  /// result straight into [ctaBlockedReason]:
  ///
  /// ```dart
  /// ctaBlockedReason: WizardScaffold.firstUnmet({
  ///   'Add a reference photo, a voice note or a sketch before continuing.': draft.hasReference,
  ///   'Choose who the piece is for.': draft.customerId != null,
  /// }),
  /// ```
  ///
  /// Map literals keep insertion order, so the reason shown is deterministic — put the cheapest
  /// fix first.
  static String? firstUnmet(Map<String, bool> requirements) {
    for (final entry in requirements.entries) {
      if (!entry.value) return entry.key;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scheme.surface,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(
              step: step,
              totalSteps: totalSteps,
              title: title,
              subtitle: subtitle,
              onBack: onBack,
              onClose: onClose,
              trailing: trailing,
            ),
            Expanded(
              child: Scrollbar(
                controller: scrollController,
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: bodyPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ),
            ),
            _Footer(
              ctaLabel: ctaLabel,
              ctaIcon: ctaIcon,
              onCta: _ctaEnabled ? onCta : null,
              blockedReason: ctaBlockedReason,
              secondaryLabel: secondaryLabel,
              onSecondary: busy ? null : onSecondary,
              footerNote: footerNote,
              busy: busy,
            ),
          ],
        ),
      ),
    );
  }
}

final class _Header extends StatelessWidget {
  const _Header({
    required this.step,
    required this.totalSteps,
    required this.title,
    required this.subtitle,
    required this.onBack,
    required this.onClose,
    required this.trailing,
  });

  final int step;
  final int totalSteps;
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final VoidCallback? onClose;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: dh.outlineVariant)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.sm, Spacing.sm, Spacing.md, Spacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (onBack != null)
                  IconButton(
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                    tooltip: 'Back one step',
                  )
                else
                  const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        // Zero-padded and monospaced so the header does not reflow between
                        // step 9 and step 10.
                        'STEP ${step.toString().padLeft(2, '0')} / '
                        '${totalSteps.toString().padLeft(2, '0')}',
                        style: AppTheme.mono(
                          size: 10.5,
                          weight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ).copyWith(letterSpacing: 1.1),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        title,
                        style: context.text.headlineSmall?.copyWith(color: scheme.onSurface),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: Spacing.xs),
                        Text(
                          subtitle!,
                          style: context.text.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: Spacing.sm), trailing!],
                if (onClose != null)
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Leave the wizard — the draft is kept',
                  ),
              ],
            ),
          ),
          _Progress(value: step / totalSteps),
        ],
      ),
    );
  }
}

/// A 3px bar that animates to its new value on step change, and jumps straight there under
/// reduced motion.
final class _Progress extends StatelessWidget {
  const _Progress({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.clamp(0.0, 1.0)),
      duration: context.motion(Motion.normal),
      curve: context.motionCurve,
      builder: (context, t, _) => LinearProgressIndicator(
        value: t,
        minHeight: 3,
        backgroundColor: context.dh.surfaceContainerHigh,
        valueColor: AlwaysStoppedAnimation(context.scheme.primary),
      ),
    );
  }
}

final class _Footer extends StatelessWidget {
  const _Footer({
    required this.ctaLabel,
    required this.ctaIcon,
    required this.onCta,
    required this.blockedReason,
    required this.secondaryLabel,
    required this.onSecondary,
    required this.footerNote,
    required this.busy,
  });

  final String ctaLabel;
  final IconData? ctaIcon;
  final VoidCallback? onCta;
  final String? blockedReason;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final String? footerNote;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    Widget cta = FilledButton(
      onPressed: onCta,
      child: busy
          ? SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onPrimary),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(ctaLabel),
                if (ctaIcon != null) ...[
                  const SizedBox(width: Spacing.sm),
                  Icon(ctaIcon, size: 18),
                ],
              ],
            ),
    );

    // Belt and braces: the strip below already states the reason in full, and the tooltip catches
    // the operator who long-presses the dead button instead of reading.
    if (blockedReason != null) {
      cta = Tooltip(message: blockedReason!, child: cta);
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: dh.surfaceContainerLowest,
        border: Border(top: BorderSide(color: dh.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (blockedReason != null) ...[
                _BlockedStrip(reason: blockedReason!),
                const SizedBox(height: Spacing.sm + Spacing.xs),
              ],
              if (secondaryLabel != null)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onSecondary,
                        child: Text(secondaryLabel!),
                      ),
                    ),
                    const SizedBox(width: Spacing.sm + Spacing.xs),
                    Expanded(flex: 2, child: cta),
                  ],
                )
              else
                cta,
              if (footerNote != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  footerNote!,
                  textAlign: TextAlign.center,
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The visible half of the gate. Gold rather than red: nothing has gone wrong, the step is simply
/// not finished yet.
final class _BlockedStrip extends StatelessWidget {
  const _BlockedStrip({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final dh = context.dh;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm + Spacing.xs,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: dh.gold.withValues(alpha: 0.14),
        borderRadius: Radii.rMd,
        border: Border.all(color: dh.gold.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded, size: 16, color: dh.goldText),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              reason,
              style: context.text.bodySmall?.copyWith(color: dh.goldText),
            ),
          ),
        ],
      ),
    );
  }
}
