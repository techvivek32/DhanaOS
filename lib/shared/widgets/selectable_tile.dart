/// The big tap target the intake wizard is built out of: icon, title, one line of plain-English
/// blurb, and a trailing affordance.
///
/// Fixed from the source: the mockups' tiles had **no selected state in the markup at all** — the
/// only differentiated tile in the whole corpus was a hardcoded "Other" that shipped
/// pre-selected with no follow-up field. So an operator tapping a job type had no feedback that
/// the tap registered. This tile has a real selected state (2px ring plus a check that replaces
/// the chevron) and a disabled state that says *why* it is disabled instead of just going grey.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/shared/widgets/dh_card.dart';
import 'package:dhanaos/shared/widgets/reduced_motion.dart';

final class SelectableTile extends StatelessWidget {
  const SelectableTile({
    super.key,
    required this.title,
    this.blurb,
    this.icon,
    this.leading,
    this.selected = false,
    this.onTap,
    this.trailing,
    this.enabled = true,
    this.disabledReason,
    this.dense = false,
    this.badge,
    this.inGroup = false,
  });

  final String title;

  /// One sentence in the operator's language. The mockups' best tiles all carried one
  /// ("Mounting customer materials"); the weakest carried none.
  final String? blurb;

  final IconData? icon;

  /// Use instead of [icon] for a metal swatch, a thumbnail or a partner avatar.
  final Widget? leading;

  final bool selected;
  final VoidCallback? onTap;

  /// Replaces the chevron/check. Pass a price, a lead time, a [Switch].
  final Widget? trailing;

  final bool enabled;

  /// Shown under the blurb and as the long-press tooltip when [enabled] is false. A tile that
  /// cannot be chosen must say what would make it choosable.
  final String? disabledReason;

  final bool dense;

  /// A chip or [ReqTag] pinned to the title row.
  final Widget? badge;

  /// Marks the tile as one option of a mutually exclusive set, for screen readers.
  final bool inGroup;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final interactive = enabled && onTap != null;

    // Disabled tiles dim through colour, not an Opacity layer, so the 1px border stays crisp.
    final titleColor = enabled ? scheme.onSurface : scheme.onSurfaceVariant;
    final glyphBg = selected
        ? scheme.secondary
        : (enabled ? dh.surfaceContainerHigh : dh.surfaceContainerLow);
    final glyphFg = selected
        ? scheme.onSecondary
        : (enabled ? scheme.onSurfaceVariant : dh.outlineVariant);

    final size = dense ? 34.0 : 42.0;

    Widget? glyph;
    if (leading != null) {
      glyph = SizedBox(width: size, height: size, child: leading);
    } else if (icon != null) {
      glyph = AnimatedContainer(
        duration: context.motion(Motion.fast),
        curve: context.motionCurve,
        width: size,
        height: size,
        decoration: BoxDecoration(color: glyphBg, borderRadius: Radii.rMd),
        child: Center(child: Icon(icon, size: dense ? 18 : 22, color: glyphFg)),
      );
    }

    final Widget tail = trailing ??
        (selected
            ? _SelectedCheck(size: dense ? 20 : 24)
            : Icon(
                Icons.chevron_right_rounded,
                size: 22,
                color: enabled ? scheme.onSurfaceVariant : dh.outlineVariant,
              ));

    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (glyph != null) ...[glyph, SizedBox(width: dense ? Spacing.sm : Spacing.md)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: context.text.titleMedium?.copyWith(
                        color: titleColor,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (badge != null) ...[const SizedBox(width: Spacing.sm), badge!],
                ],
              ),
              if (blurb != null) ...[
                const SizedBox(height: 2),
                Text(
                  blurb!,
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (!enabled && disabledReason != null) ...[
                const SizedBox(height: Spacing.xs),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 13, color: dh.goldText),
                    const SizedBox(width: Spacing.xs),
                    Expanded(
                      child: Text(
                        disabledReason!,
                        style: context.text.bodySmall?.copyWith(color: dh.goldText),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        SizedBox(width: dense ? Spacing.sm : Spacing.md),
        tail,
      ],
    );

    Widget tile = DhCard(
      onTap: interactive ? onTap : null,
      selected: selected,
      tone: enabled ? DhCardTone.raised : DhCardTone.inset,
      padding: EdgeInsets.symmetric(
        horizontal: dense ? Spacing.sm + Spacing.xs : Spacing.md,
        vertical: dense ? Spacing.sm + Spacing.xs : Spacing.md - 2,
      ),
      child: body,
    );

    if (!enabled && disabledReason != null) {
      tile = Tooltip(message: disabledReason!, child: tile);
    }

    return MergeSemantics(
      child: Semantics(
        button: interactive,
        enabled: enabled,
        selected: selected,
        inMutuallyExclusiveGroup: inGroup,
        child: tile,
      ),
    );
  }
}

/// The check that replaces the chevron. Scales in, so the state change is visible even to
/// someone who was not looking directly at the tile — and settles instantly under reduced motion.
final class _SelectedCheck extends StatelessWidget {
  const _SelectedCheck({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.6, end: 1),
      duration: context.motion(Motion.fast),
      curve: context.motionCurve,
      builder: (context, t, child) => Transform.scale(scale: t, child: child),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: scheme.secondary, shape: BoxShape.circle),
        child: Center(
          child: Icon(Icons.check_rounded, size: size * 0.66, color: scheme.onSecondary),
        ),
      ),
    );
  }
}

/// A single-select column of [SelectableTile]s over any value type — most usefully an enum,
/// since every DhanaOS enum already carries `.label` and several carry `.blurb`.
///
/// ```dart
/// SelectableTileGroup<JobType>(
///   values: JobType.values,
///   selected: type,
///   labelOf: (t) => t.label,
///   blurbOf: (t) => t.blurb,
///   iconOf: (t) => switch (t) { JobType.repair => Icons.build_outlined, _ => Icons.diamond_outlined },
///   onChanged: (t) => ref.read(draftProvider.notifier).setType(t),
/// )
/// ```
final class SelectableTileGroup<T> extends StatelessWidget {
  const SelectableTileGroup({
    super.key,
    required this.values,
    required this.selected,
    required this.onChanged,
    required this.labelOf,
    this.blurbOf,
    this.iconOf,
    this.enabledOf,
    this.disabledReasonOf,
    this.badgeOf,
    this.spacing = Spacing.sm + Spacing.xs,
    this.dense = false,
  });

  final List<T> values;
  final T? selected;
  final ValueChanged<T> onChanged;
  final String Function(T) labelOf;
  final String? Function(T)? blurbOf;
  final IconData? Function(T)? iconOf;
  final bool Function(T)? enabledOf;
  final String? Function(T)? disabledReasonOf;
  final Widget? Function(T)? badgeOf;
  final double spacing;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < values.length; i++) ...[
          if (i > 0) SizedBox(height: spacing),
          SelectableTile(
            title: labelOf(values[i]),
            blurb: blurbOf?.call(values[i]),
            icon: iconOf?.call(values[i]),
            badge: badgeOf?.call(values[i]),
            enabled: enabledOf?.call(values[i]) ?? true,
            disabledReason: disabledReasonOf?.call(values[i]),
            selected: selected == values[i],
            dense: dense,
            inGroup: true,
            onTap: () => onChanged(values[i]),
          ),
        ],
      ],
    );
  }
}
