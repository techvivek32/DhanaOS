/// The container every surface in DhanaOS is built from.
///
/// The source spec was explicit and unusual about this: **1px border, no shadow.** Every one of
/// the 46 mockups drew its cards that way, and the light theme's near-white ground (`#f7f9fb`)
/// against a pure-white card (`#ffffff`) only reads as a card because of that hairline. Material's
/// default elevation would flatten the distinction into a grey smear, so `CardTheme` is bypassed
/// and the border is drawn here where it cannot be overridden by accident.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/shared/widgets/reduced_motion.dart';

/// Which ground the card sits on. The dark theme stacks three container levels, so a card inside
/// a card must step up rather than repeat.
enum DhCardTone {
  /// Default. White in light, the glass fill `#112036` in dark.
  raised,

  /// A nested block inside another card — a cost line, a checklist item.
  inset,

  /// Draws the border only, no fill. For grouping without adding weight.
  outline,
}

final class DhCard extends StatelessWidget {
  const DhCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Spacing.md),
    this.tone = DhCardTone.raised,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.borderRadius = Radii.rLg,
    this.borderColor,
    this.background,
    this.accent,
    this.semanticLabel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final DhCardTone tone;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Draws a 2px ring instead of the hairline. Used by [SelectableTile] and the review step.
  final bool selected;

  final BorderRadius borderRadius;
  final Color? borderColor;
  final Color? background;

  /// A 3px bar down the leading edge. The mockups used it for milestone and exception cards —
  /// pass `context.dh.gold` for a milestone, `context.scheme.error` for an exception.
  final Color? accent;

  final String? semanticLabel;

  Color _background(BuildContext context) {
    if (background != null) return background!;
    final dh = context.dh;
    return switch (tone) {
      DhCardTone.raised => dh.surfaceContainerLowest,
      DhCardTone.inset => dh.surfaceContainerLow,
      DhCardTone.outline => Colors.transparent,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final resolvedBorder = selected
        ? scheme.secondary
        : (borderColor ?? context.dh.outlineVariant);

    Widget content = Padding(padding: padding, child: child);

    if (accent != null) {
      // The card takes its content's height and the bar fills it. A stretched Row cannot do
      // that inside a scroll view, where the height it would stretch to is infinite.
      content = Stack(
        children: [
          Padding(padding: const EdgeInsets.only(left: 3), child: content),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 3,
            child: ColoredBox(color: accent!),
          ),
        ],
      );
    }

    if (onTap != null || onLongPress != null) {
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: borderRadius,
          child: content,
        ),
      );
    }

    final card = AnimatedContainer(
      duration: context.motion(Motion.fast),
      curve: context.motionCurve,
      decoration: BoxDecoration(
        color: _background(context),
        borderRadius: borderRadius,
        // No shadow. Ever. See the library comment.
        border: Border.all(color: resolvedBorder, width: selected ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );

    return semanticLabel == null
        ? card
        : Semantics(label: semanticLabel, selected: selected, child: card);
  }
}

/// A titled card. The mockups repeated this header shape on every panel: an uppercase mono
/// section label on the left, an optional action on the right, a hairline, then the body.
final class DhSectionCard extends StatelessWidget {
  const DhSectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.action,
    this.leading,
    this.tone = DhCardTone.raised,
    this.accent,
    this.padding = const EdgeInsets.all(Spacing.md),
    this.divided = true,
  });

  final String title;
  final String? subtitle;

  /// A button or chip pinned to the header's right edge.
  final Widget? action;
  final Widget? leading;
  final Widget child;
  final DhCardTone tone;
  final Color? accent;
  final EdgeInsetsGeometry padding;

  /// Hairline between header and body. Off for cards whose body is itself a list of rows.
  final bool divided;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return DhCard(
      tone: tone,
      accent: accent,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.md,
              Spacing.md,
              Spacing.sm + Spacing.xs,
            ),
            child: Row(
              children: [
                if (leading != null) ...[
                  IconTheme(
                    data: IconThemeData(size: 18, color: scheme.onSurfaceVariant),
                    child: leading!,
                  ),
                  const SizedBox(width: Spacing.sm),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.toUpperCase(),
                        style: context.text.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
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
                if (action != null) action!,
              ],
            ),
          ),
          if (divided) Divider(height: 1, thickness: 1, color: context.dh.outlineVariant),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}
