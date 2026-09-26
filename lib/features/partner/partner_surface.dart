/// The pieces the three vendor screens share: the shop-floor palette, the derived state chip, the
/// critical-value cell and the job identity line.
///
/// **Why the palette is pinned here.** D-010 says light is the product default and dark is the
/// shop-floor and mobile theme, and every one of the 46 mockups declared `darkMode:"class"` while
/// containing zero `dark:` variants — light and dark shipped as complete standalone palettes bound
/// to the same token names. That is what makes pinning safe rather than a shortcut: nothing inside
/// these screens contains a colour, radius or spacing literal, so each widget still renders
/// correctly in either palette. What [ShopFloorSurface] decides is only which of the two a caster
/// standing at a furnace gets — and on a shop floor that is the dark one, whatever the tablet's
/// system setting happens to be.
///
/// **Why the critical value is its own component.** `caster_dashboard` rendered the metal
/// temperature larger and hotter than everything else on the card, because pouring 18K at 1020 °C
/// and pouring it at 1200 °C are not equivalent mistakes. Making it a component keeps that
/// emphasis from drifting back into a plain [DataPair] the next time the card is edited.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/features/partner/partner_gateway.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

/// Built once. `AppTheme.dark()` resolves Google Fonts text themes, which is not work to repeat
/// on every rebuild of every vendor screen.
final ThemeData _shopFloorTheme = AppTheme.dark();

/// The vendor world, in the shop-floor palette.
///
/// The [ColoredBox] is not decoration: a `Theme` alone changes what descendants *read*, and the
/// ground behind a transparent body would still come from the surrounding shell. Painting it here
/// means the content region is unambiguously this palette.
final class ShopFloorSurface extends StatelessWidget {
  const ShopFloorSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(
        data: _shopFloorTheme,
        child: ColoredBox(
          color: _shopFloorTheme.colorScheme.surface,
          child: child,
        ),
      );
}

// ================================================================= chips

/// What is outstanding on one outsourced stage. Derived, never stored — see [PartnerWorkState].
final class PartnerStateChip extends StatelessWidget {
  const PartnerStateChip(this.state, {super.key, this.dense = false});

  final PartnerWorkState state;
  final bool dense;

  @override
  Widget build(BuildContext context) => StatusChip(
        label: state.label,
        dense: dense,
        tooltip: state.blurb,
        tone: switch (state) {
          PartnerWorkState.blocked => ChipTone.danger,
          // Gold, not red: a missing photo is the next thing to do, not a fault.
          PartnerWorkState.awaitingEvidence => ChipTone.warning,
          PartnerWorkState.readyToClose => ChipTone.success,
        },
        icon: switch (state) {
          PartnerWorkState.blocked => Icons.report_problem_outlined,
          PartnerWorkState.awaitingEvidence => Icons.photo_camera_outlined,
          PartnerWorkState.readyToClose => Icons.check_circle_outline_rounded,
        },
      );
}

// ================================================================= identity line

/// A job as a vendor is allowed to see it: the code, what it is, and how urgent.
///
/// There is deliberately no customer name and no value. All 46 mockups leaked one hardcoded
/// internal identity onto the vendor's screen; `v_partner_queue` carries neither field, and this
/// component has nowhere to put them even if a caller tried.
final class VendorJobLine extends StatelessWidget {
  const VendorJobLine({
    super.key,
    required this.code,
    required this.title,
    required this.priority,
    this.stage,
    this.trailing,
  });

  /// 'DH-2026-01842' — monospace, because it is data (convention 5).
  final String code;

  final String title;
  final Priority priority;

  /// Which rail stage is out with this vendor.
  final LifecycleStage? stage;

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
              Row(
                children: [
                  Flexible(
                    child: Text(
                      code,
                      style: AppTheme.mono(
                        size: 12.5,
                        weight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (stage != null) ...[
                    const SizedBox(width: Spacing.sm),
                    StatusChip.lifecycle(stage!, dense: true),
                  ],
                  const SizedBox(width: Spacing.sm),
                  PriorityChip(priority, dense: true, showStandard: false),
                ],
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

// ================================================================= critical value

/// One figure a caster must not misread.
///
/// `caster_dashboard` drew the metal temperature hotter and larger than the rest of the spec card.
/// [CriticalValue.hazard] keeps that: gold ground, gold ink, the figure at display size. The flask
/// temperature and the alloy sit beside it as ordinary pairs, which is the point — if everything
/// shouts, nothing does.
final class CriticalValue extends StatelessWidget {
  const CriticalValue({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.hazard = false,
    this.icon,
  });

  /// The hot one. Only ever one per card.
  const CriticalValue.hazard({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.icon = Icons.local_fire_department_outlined,
  }) : hazard = true;

  final String label;

  /// Rendered monospaced at display size. Pass the number with its unit — '1020 °C'.
  final String value;

  /// A line under the figure — 'Pour within ± 15 °C'.
  final String? caption;

  final bool hazard;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final ink = hazard ? dh.goldText : scheme.onSurface;

    return DhCard(
      tone: hazard ? DhCardTone.raised : DhCardTone.inset,
      background: hazard ? dh.gold.withValues(alpha: 0.10) : null,
      borderColor: hazard ? dh.gold.withValues(alpha: 0.45) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: hazard ? dh.goldText : scheme.onSurfaceVariant),
                const SizedBox(width: Spacing.xs + 2),
              ],
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: context.text.labelSmall?.copyWith(
                    color: hazard ? dh.goldText : scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            value,
            style: AppTheme.mono(size: 26, weight: FontWeight.w700, color: ink),
            maxLines: 1,
          ),
          if (caption != null) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              caption!,
              style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= gate strip

/// The sentence under a control that is deliberately shut.
///
/// D-011 rule 1's helper — "Required before marking complete" — was the one piece of honest
/// microcopy in the corpus, and it only works because it sits *attached* to the disabled button.
/// Never render a dead control without one of these.
final class GateNote extends StatelessWidget {
  const GateNote({
    super.key,
    required this.reason,
    this.icon = Icons.lock_outline_rounded,
    this.tone = GateTone.blocked,
  });

  final String reason;
  final IconData icon;
  final GateTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final (Color ground, Color ink) = switch (tone) {
      GateTone.blocked => (dh.gold.withValues(alpha: 0.12), dh.goldText),
      GateTone.risk => (scheme.errorContainer, scheme.onErrorContainer),
      GateTone.calm => (dh.surfaceContainerLow, scheme.onSurfaceVariant),
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
            child: Text(
              reason,
              style: context.text.bodySmall?.copyWith(color: ink),
            ),
          ),
        ],
      ),
    );
  }
}

enum GateTone { blocked, risk, calm }

/// A 16px spinner sized to sit inside a button's icon slot.
final class ButtonSpinner extends StatelessWidget {
  const ButtonSpinner({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
}
