/// Status pills, colour-mapped from the domain enums rather than from a string.
///
/// The mockups hardcoded every badge — "In Production" was a literal class list, and the same
/// state wore three different colours on three screens. Here the mapping lives in one place and
/// takes the enum, so a state can never be painted two ways.
///
/// Two corrections carried over from the token work: chips are real pills (the exports overrode
/// the radius scale, which turned `rounded-full` into a 12px square), and every tone is defined
/// as a *pair* so it survives both themes — a soft tint plus its own readable foreground.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';

/// The six meanings a chip can carry. Nothing in the app picks chip colours directly.
enum ChipTone {
  /// Nothing is happening yet, or it is over and unremarkable.
  neutral,

  /// Work in flight. Indigo in light, pale blue in dark.
  accent,

  /// Settled well.
  success,

  /// Needs a human — approvals waiting, holds, counter-offers. The house gold.
  warning,

  /// Failed, rejected, cancelled.
  danger,

  /// Maximum emphasis: black in light, gold in dark. One per screen at most.
  strong,
}

@immutable
final class _ToneColors {
  const _ToneColors(this.background, this.foreground, this.border);
  final Color background;
  final Color foreground;
  final Color? border;
}

final class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    this.tone = ChipTone.neutral,
    this.icon,
    this.dot = false,
    this.dense = false,
    this.mono = false,
    this.tooltip,
  });

  // ---------------------------------------------------------------- enum constructors

  /// D-006 — `onHold`, `rework` and `cancelled` had no mockup at all; every gate there was
  /// one-way. They are coloured here because they will exist from Phase 2.
  factory StatusChip.job(JobStatus status, {Key? key, bool dense = false}) => StatusChip(
        key: key,
        label: status.label,
        dense: dense,
        tone: switch (status) {
          JobStatus.draft || JobStatus.archived => ChipTone.neutral,
          JobStatus.pendingApproval || JobStatus.onHold => ChipTone.warning,
          JobStatus.approvedReady || JobStatus.inProduction => ChipTone.accent,
          JobStatus.rework || JobStatus.cancelled => ChipTone.danger,
          JobStatus.completed => ChipTone.success,
        },
      );

  /// D-002 — one node of the 14-stage rail.
  factory StatusChip.stage(StageState state, {Key? key, bool dense = false}) => StatusChip(
        key: key,
        label: state.label,
        dense: dense,
        dot: true,
        tone: switch (state) {
          StageState.pending || StageState.skipped => ChipTone.neutral,
          StageState.active => ChipTone.accent,
          StageState.completed => ChipTone.success,
          StageState.blocked => ChipTone.danger,
        },
      );

  /// The stage name itself — "Casting", "Polishing". Never colour-coded: the rail carries
  /// position, the chip only carries the word.
  factory StatusChip.lifecycle(LifecycleStage stage, {Key? key, bool dense = false}) =>
      StatusChip(key: key, label: stage.label, dense: dense);

  /// D-006 — `failed` was designed in the mockup's CSS (its JS removed a `bg-error` class in an
  /// else branch) and left unreachable. It is reachable here.
  factory StatusChip.qc(QcStatus status, {Key? key, bool dense = false}) => StatusChip(
        key: key,
        label: status.label,
        dense: dense,
        tone: switch (status) {
          QcStatus.pending => ChipTone.neutral,
          QcStatus.inProgress => ChipTone.accent,
          QcStatus.ready => ChipTone.warning,
          QcStatus.approved => ChipTone.success,
          QcStatus.failed => ChipTone.danger,
        },
        icon: switch (status) {
          QcStatus.approved => Icons.verified_rounded,
          QcStatus.failed => Icons.report_gmailerrorred_rounded,
          _ => null,
        },
      );

  factory StatusChip.cert(CertStatus status, {Key? key, bool dense = false}) => StatusChip(
        key: key,
        label: status.label,
        dense: dense,
        tone: switch (status) {
          CertStatus.waiting || CertStatus.returned => ChipTone.neutral,
          CertStatus.sent || CertStatus.atLab || CertStatus.inProgress => ChipTone.accent,
          CertStatus.certified => ChipTone.success,
          CertStatus.rejected => ChipTone.danger,
        },
      );

  factory StatusChip.quote(QuoteStatus status, {Key? key, bool dense = false}) => StatusChip(
        key: key,
        label: status.label,
        dense: dense,
        tone: switch (status) {
          QuoteStatus.draft || QuoteStatus.expired => ChipTone.neutral,
          QuoteStatus.sent => ChipTone.accent,
          QuoteStatus.approved => ChipTone.success,
          QuoteStatus.counterOffered => ChipTone.warning,
          QuoteStatus.rejected => ChipTone.danger,
        },
      );

  /// The field that survived in exactly one of 46 mockups (D-012). Deliberately **not**
  /// colour-coded: natural and lab-grown are not better and worse, they are different
  /// disclosure obligations. The icons distinguish them; the tone stays neutral so nobody reads
  /// a price signal into it. What matters is that it is on screen at all.
  factory StatusChip.origin(StoneOrigin origin, {Key? key, bool dense = false}) => StatusChip(
        key: key,
        label: origin.label,
        dense: dense,
        icon: switch (origin) {
          StoneOrigin.natural => Icons.terrain_rounded,
          StoneOrigin.labGrown => Icons.science_outlined,
        },
      );

  /// A job code, SKU or certificate number. Monospace, because it is data (convention 5).
  factory StatusChip.code(String code, {Key? key, bool dense = false, ChipTone? tone}) =>
      StatusChip(
        key: key,
        label: code,
        mono: true,
        dense: dense,
        tone: tone ?? ChipTone.neutral,
      );

  final String label;
  final ChipTone tone;
  final IconData? icon;

  /// Leading 6px dot in the foreground colour, for live-state chips.
  final bool dot;

  final bool dense;

  /// Renders the label in the monospace face. True for anything that is an identifier.
  final bool mono;

  final String? tooltip;

  static _ToneColors _colors(BuildContext context, ChipTone tone) {
    final scheme = context.scheme;
    final dh = context.dh;
    return switch (tone) {
      ChipTone.neutral =>
        _ToneColors(dh.surfaceContainerHigh, scheme.onSurfaceVariant, dh.outlineVariant),
      ChipTone.accent =>
        _ToneColors(scheme.secondaryContainer, scheme.onSecondaryContainer, null),
      ChipTone.success => _ToneColors(dh.successContainer, dh.success, null),
      // A soft gold tint rather than solid gold: a pill this size in full #F7BE1D shouts.
      ChipTone.warning => _ToneColors(dh.gold.withValues(alpha: 0.18), dh.goldText, null),
      ChipTone.danger => _ToneColors(scheme.errorContainer, scheme.onErrorContainer, null),
      ChipTone.strong => _ToneColors(scheme.primary, scheme.onPrimary, null),
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = _colors(context, tone);
    final fontSize = dense ? 10.5 : 11.5;

    final labelWidget = Text(
      mono ? label : label.toUpperCase(),
      style: mono
          ? AppTheme.mono(size: fontSize + 0.5, weight: FontWeight.w600, color: c.foreground)
          : context.text.labelSmall?.copyWith(
              color: c.foreground,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    final chip = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? Spacing.sm : Spacing.sm + Spacing.xs,
        vertical: dense ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: c.background,
        borderRadius: Radii.rFull,
        border: c.border == null ? null : Border.all(color: c.border!),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: c.foreground, shape: BoxShape.circle),
            ),
            const SizedBox(width: Spacing.xs + 2),
          ],
          if (icon != null) ...[
            Icon(icon, size: fontSize + 3, color: c.foreground),
            const SizedBox(width: Spacing.xs),
          ],
          Flexible(child: labelWidget),
        ],
      ),
    );

    final message = tooltip;
    return message == null ? chip : Tooltip(message: message, child: chip);
  }
}

/// Activity-feed and exception severity. The mockups' "Immutable Audit Trail" rendered every
/// entry in the same grey; severity is what makes a long feed scannable.
final class SeverityChip extends StatelessWidget {
  const SeverityChip(this.severity, {super.key, this.label, this.dense = false});

  final ActionSeverity severity;

  /// Overrides the default word — pass the actual exception, e.g. "Caster delayed".
  final String? label;

  final bool dense;

  static const _words = {
    ActionSeverity.info: 'Info',
    ActionSeverity.warning: 'Attention',
    ActionSeverity.error: 'Exception',
    ActionSeverity.success: 'Cleared',
  };

  @override
  Widget build(BuildContext context) => StatusChip(
        label: label ?? _words[severity]!,
        dense: dense,
        tone: switch (severity) {
          ActionSeverity.info => ChipTone.accent,
          ActionSeverity.warning => ChipTone.warning,
          ActionSeverity.error => ChipTone.danger,
          ActionSeverity.success => ChipTone.success,
        },
        icon: switch (severity) {
          ActionSeverity.info => Icons.info_outline_rounded,
          ActionSeverity.warning => Icons.warning_amber_rounded,
          ActionSeverity.error => Icons.error_outline_rounded,
          ActionSeverity.success => Icons.check_circle_outline_rounded,
        },
      );
}

/// Job priority. The token notes record indigo as the source system's priority-badge colour, so
/// Rush takes the accent tone; Critical escalates to danger because it changes what the shop
/// floor does next.
final class PriorityChip extends StatelessWidget {
  const PriorityChip(this.priority, {super.key, this.dense = false, this.showStandard = true});

  final Priority priority;
  final bool dense;

  /// Most jobs are Standard. On a dense list, pass false and render nothing for the default —
  /// a badge that appears on every row carries no information.
  final bool showStandard;

  @override
  Widget build(BuildContext context) {
    if (priority == Priority.standard && !showStandard) return const SizedBox.shrink();
    return StatusChip(
      label: priority.label,
      dense: dense,
      tone: switch (priority) {
        Priority.standard => ChipTone.neutral,
        Priority.rush => ChipTone.accent,
        Priority.critical => ChipTone.danger,
      },
      icon: switch (priority) {
        Priority.standard => null,
        Priority.rush => Icons.bolt_rounded,
        Priority.critical => Icons.priority_high_rounded,
      },
    );
  }
}
