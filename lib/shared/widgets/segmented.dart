/// The sliding segmented control. Two-to-four mutually exclusive options that share one row.
///
/// The source system used exactly one easing curve for this slide — recovered as [Motion.curve] —
/// and used the control for both sourcing (`Needs Sourcing / In Stock / Customer Supplied`) and
/// units. What it did *not* do was move: none of the segmented controls in the 46 mockups carried
/// any JavaScript, so the active segment was whichever one the exporter had hardcoded.
///
/// Use this only for a small closed set whose options are short words. Anything longer, or with a
/// blurb, belongs in a `SelectableTile` column.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/shared/widgets/reduced_motion.dart';

@immutable
final class DhSegment<T> {
  const DhSegment({
    required this.value,
    required this.label,
    this.icon,
    this.enabled = true,
    this.disabledReason,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool enabled;

  /// Long-press explanation when the segment cannot be chosen — e.g. "No stock of this grade
  /// in the vault."
  final String? disabledReason;
}

final class DhSegmented<T> extends StatelessWidget {
  const DhSegmented({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
    this.label,
    this.dense = false,
    this.accent = false,
  }) : assert(segments.length > 1, 'A segmented control needs at least two segments.');

  final List<DhSegment<T>> segments;

  /// The selected value. When it matches no segment nothing is highlighted, which is the honest
  /// rendering of "not yet answered" — better than the mockups' silently pre-selected first option.
  final T? value;

  final ValueChanged<T> onChanged;

  /// Optional uppercase mono micro-label above the control, matching `DataPair`.
  final String? label;

  final bool dense;

  /// Fills the thumb with `primary` (black in light, gold in dark) instead of a neutral. Reserve
  /// it for a control that is itself the primary decision on the screen.
  final bool accent;

  static const _fallbackWidth = 320.0;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final index = segments.indexWhere((s) => s.value == value);
    final height = dense ? 36.0 : 44.0;
    const inset = 3.0;

    // The neutral thumb has to step the *opposite* way in each theme: white lifts off the light
    // track, while in dark it is the higher container that lifts off the #112036 glass.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final thumbColor = accent
        ? scheme.primary
        : (isDark ? dh.surfaceContainerHigh : dh.surfaceContainerLowest);
    final selectedFg = accent ? scheme.onPrimary : scheme.onSurface;

    final control = LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.maxWidth.isFinite ? constraints.maxWidth : _fallbackWidth;
        final segmentWidth = width / segments.length;

        return SizedBox(
          height: height,
          width: width,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: dh.surfaceContainerLow,
              borderRadius: Radii.rMd,
              border: Border.all(color: dh.outlineVariant),
            ),
            child: Stack(
              children: [
                if (index >= 0)
                  AnimatedPositioned(
                    duration: context.motion(Motion.normal),
                    curve: context.motionCurve,
                    left: segmentWidth * index + inset,
                    top: inset,
                    bottom: inset,
                    width: segmentWidth - inset * 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: thumbColor,
                        borderRadius: Radii.rSm,
                        border: accent
                            ? null
                            : Border.all(color: dh.outlineVariant),
                      ),
                    ),
                  ),
                // Fill the track: a non-positioned Stack child is sized to its content and pinned
                // to the top, which left every label riding the upper edge of the thumb.
                Positioned.fill(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < segments.length; i++)
                        _SegmentLabel<T>(
                          segment: segments[i],
                          width: segmentWidth,
                          selected: i == index,
                          selectedFg: selectedFg,
                          dense: dense,
                          onTap: segments[i].enabled
                              ? () => onChanged(segments[i].value)
                              : null,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (label == null) return control;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label!.toUpperCase(),
          style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: Spacing.sm),
        control,
      ],
    );
  }
}

final class _SegmentLabel<T> extends StatelessWidget {
  const _SegmentLabel({
    required this.segment,
    required this.width,
    required this.selected,
    required this.selectedFg,
    required this.dense,
    required this.onTap,
  });

  final DhSegment<T> segment;
  final double width;
  final bool selected;
  final Color selectedFg;
  final bool dense;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final fg = selected
        ? selectedFg
        : (segment.enabled ? scheme.onSurfaceVariant : context.dh.outlineVariant);

    Widget content = AnimatedDefaultTextStyle(
      duration: context.motion(Motion.fast),
      curve: context.motionCurve,
      style: (context.text.bodyMedium ?? const TextStyle()).copyWith(
        color: fg,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        fontSize: dense ? 13 : 14,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (segment.icon != null) ...[
            Icon(segment.icon, size: dense ? 15 : 17, color: fg),
            const SizedBox(width: Spacing.xs + 2),
          ],
          Flexible(
            child: Text(
              segment.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );

    if (segment.disabledReason != null && !segment.enabled) {
      content = Tooltip(message: segment.disabledReason!, child: content);
    }

    return SizedBox(
      width: width,
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        selected: selected,
        enabled: segment.enabled,
        button: true,
        label: segment.label,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
            child: Center(child: content),
          ),
        ),
      ),
    );
  }
}
