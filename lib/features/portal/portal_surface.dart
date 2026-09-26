/// The pieces the three portal screens share: the client palette, the phase bar, the decision
/// chip and the order identity line.
///
/// **Why the palette is pinned here.** D-010 makes light the product default and dark the
/// shop-floor theme, and the portal is neither shop floor nor phone — it is a retailer's desk. All
/// 46 mockups declared `darkMode:"class"` while containing zero `dark:` variants, because light
/// and dark shipped as complete standalone palettes bound to the same token names. That is what
/// makes pinning safe rather than a shortcut: nothing inside these screens carries a colour,
/// radius or spacing literal, so every widget still renders correctly in either palette.
/// [ClientSurface] only decides which one a client gets.
///
/// Nothing in this file has a vendor equivalent on purpose. The partner surface and the portal are
/// two different audiences with two different palettes and two different vocabularies — sharing a
/// component between them is how a caster's temperature card ends up on a customer's screen.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/features/portal/portal_gateway.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

/// Built once. `AppTheme.light()` resolves Google Fonts text themes, which is not work to repeat
/// on every rebuild of every portal screen.
final ThemeData _clientTheme = AppTheme.light();

/// The retailer's world, in the product's default palette.
///
/// The [ColoredBox] is not decoration: a `Theme` alone changes what descendants *read*, and the
/// ground behind a transparent body would still come from the surrounding shell.
final class ClientSurface extends StatelessWidget {
  const ClientSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(
        data: _clientTheme,
        child: ColoredBox(
          color: _clientTheme.colorScheme.surface,
          child: child,
        ),
      );
}

// ================================================================= identity

/// An order as its owner reads it: the code, what it is, and roughly where it has got to.
///
/// No stage dwell times, no assignee, no vendor. Who is holding the piece this week is the
/// workshop's business, and a client reading "4d at casting" reads it as a complaint.
final class OrderLine extends StatelessWidget {
  const OrderLine({
    super.key,
    required this.code,
    required this.title,
    this.trailing,
  });

  /// D-001 — 'DH-2026-01842'. Monospace, because it is the reference a client quotes back on the
  /// phone (convention 5).
  final String code;

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                code,
                style: AppTheme.mono(
                  size: 12.5,
                  weight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                title,
                style: context.text.titleMedium?.copyWith(color: scheme.onSurface),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: Spacing.sm),
          trailing!,
        ],
      ],
    );
  }
}

// ================================================================= progress

/// Where the piece has got to, in the client's vocabulary.
///
/// The bar is always computed — never a `style="width: 85%"` literal, which is what
/// `pricing_approval` shipped while the real figure was 90.8%. The words beside it matter more
/// than the bar: a percentage on its own tells a client nothing they can act on.
final class PortalPhaseBar extends StatelessWidget {
  const PortalPhaseBar({
    super.key,
    required this.phase,
    required this.progress,
    this.note,
    this.paused = false,
  });

  final PortalPhase phase;

  /// 0.0 .. 1.0.
  final double progress;

  /// What happens next, in a sentence.
  final String? note;

  /// D-006's `on_hold`. A stalled bar with no explanation is worse than no bar.
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                phase.label.toUpperCase(),
                style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            Text(
              '${(progress * 100).round()}%',
              style: AppTheme.mono(
                size: 12,
                weight: FontWeight.w600,
                color: paused ? dh.goldText : scheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        ClipRRect(
          borderRadius: Radii.rFull,
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: dh.surfaceContainerHigh,
            color: paused ? dh.gold : scheme.primary,
          ),
        ),
        if (note != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            note!,
            style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

// ================================================================= decisions

/// Where one decision stands. Deliberately plain about "waiting for you": a client who does not
/// notice they are the hold-up is a week the workshop loses.
final class DecisionChip extends StatelessWidget {
  const DecisionChip(this.item, {super.key, this.dense = false});

  final PortalApprovalItem item;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final (ChipTone tone, IconData icon) = switch (item) {
      _ when item.isOutstanding => (ChipTone.warning, Icons.pending_actions_outlined),
      _ when item.isSentBack => (ChipTone.accent, Icons.reply_rounded),
      _ when item.isDecided => (ChipTone.success, Icons.check_circle_outline_rounded),
      _ => (ChipTone.neutral, Icons.schedule_outlined),
    };

    return StatusChip(
      label: item.statusLabel,
      tone: tone,
      icon: icon,
      dense: dense,
      dot: item.isOutstanding,
    );
  }
}

/// A short, plain explanation under a heading or beside a control.
final class PortalNote extends StatelessWidget {
  const PortalNote({
    super.key,
    required this.text,
    this.icon = Icons.info_outline_rounded,
    this.tone = PortalNoteTone.calm,
  });

  final String text;
  final IconData icon;
  final PortalNoteTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final (Color ground, Color ink) = switch (tone) {
      PortalNoteTone.calm => (dh.surfaceContainerLow, scheme.onSurfaceVariant),
      PortalNoteTone.action => (dh.gold.withValues(alpha: 0.14), dh.goldText),
      PortalNoteTone.settled => (dh.successContainer, dh.success),
      PortalNoteTone.risk => (scheme.errorContainer, scheme.onErrorContainer),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm + Spacing.xs,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(color: ground, borderRadius: Radii.rMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: ink),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(text, style: context.text.bodySmall?.copyWith(color: ink)),
          ),
        ],
      ),
    );
  }
}

enum PortalNoteTone { calm, action, settled, risk }

/// A 16px spinner sized to sit inside a button's icon slot.
final class PortalSpinner extends StatelessWidget {
  const PortalSpinner({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
}
