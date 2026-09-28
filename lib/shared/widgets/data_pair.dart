/// The source system's signature idiom: an UPPERCASE mono micro-label sitting above its value.
///
/// It appears on every detail surface in the 46 mockups — "JOB VALUE / $4,850", "METAL / Pt950",
/// "TARGET WEIGHT / 4.8g" — and it is why the theme's `labelSmall` is a monospace face with wide
/// letter-spacing. Rendering it by hand in each feature would drift, so it is a component.
///
/// Rule: anything that is *data* — a SKU, a job code, a weight, a carat, a dimension, a
/// timestamp, a money amount — takes the monospace value. [DataPair.mono], [DataPair.money] and
/// [DataPair.timestamp] make that the default so a caller cannot forget.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';

/// How loudly the value reads. The label never changes size — only the value scales, which is
/// what keeps a column of pairs optically aligned.
enum DataEmphasis {
  /// Secondary metadata inside a dense row.
  quiet,

  /// The default for a specification line.
  normal,

  /// A figure the operator is meant to check — a weight, a total.
  strong,

  /// One hero number per card at most.
  display,
}

final class DataPair extends StatelessWidget {
  const DataPair({
    super.key,
    required this.label,
    required String this.value,
    this.mono = false,
    this.emphasis = DataEmphasis.normal,
    this.valueColor,
    this.icon,
    this.trailing,
    this.maxLines = 2,
    this.alignment = CrossAxisAlignment.start,
    this.tooltip,
  }) : child = null;

  /// Monospace value — SKUs, job codes, weights, carats, dimensions, ring sizes.
  const DataPair.mono({
    super.key,
    required this.label,
    required String this.value,
    this.emphasis = DataEmphasis.normal,
    this.valueColor,
    this.icon,
    this.trailing,
    this.maxLines = 2,
    this.alignment = CrossAxisAlignment.start,
    this.tooltip,
  })  : mono = true,
        child = null;

  /// Any widget under the label — a chip row, a metal swatch, a progress bar.
  const DataPair.custom({
    super.key,
    required this.label,
    required Widget this.child,
    this.trailing,
    this.alignment = CrossAxisAlignment.start,
    this.tooltip,
  })  : value = null,
        mono = false,
        emphasis = DataEmphasis.normal,
        valueColor = null,
        icon = null,
        maxLines = 1;

  /// D-004 — money never reaches a widget as a double. Pass the [Money] and this formats it,
  /// Indian digit grouping included.
  factory DataPair.money({
    Key? key,
    required String label,
    required Money amount,
    bool compact = false,
    DataEmphasis emphasis = DataEmphasis.strong,
    Color? valueColor,
    IconData? icon,
    Widget? trailing,
    CrossAxisAlignment alignment = CrossAxisAlignment.start,
    String? tooltip,
  }) =>
      DataPair.mono(
        key: key,
        label: label,
        value: amount.format(compact: compact),
        emphasis: emphasis,
        valueColor: valueColor,
        icon: icon,
        trailing: trailing,
        maxLines: 1,
        alignment: alignment,
        tooltip: tooltip,
      );

  /// Convention 7 — Postgres hands us UTC, the operator reads local time. Nothing else in the
  /// app should format a `DateTime` by hand.
  factory DataPair.timestamp({
    Key? key,
    required String label,
    required DateTime utc,
    bool withTime = true,
    DataEmphasis emphasis = DataEmphasis.normal,
    Color? valueColor,
    IconData? icon,
    Widget? trailing,
    CrossAxisAlignment alignment = CrossAxisAlignment.start,
  }) {
    final local = utc.toLocal();
    return DataPair.mono(
      key: key,
      label: label,
      value: DateFormat(withTime ? 'd MMM yyyy · HH:mm' : 'd MMM yyyy').format(local),
      emphasis: emphasis,
      valueColor: valueColor,
      icon: icon,
      trailing: trailing,
      // A half-width column on a phone cannot hold date and time on one line; cutting the time
      // off hides the half an operator is usually looking for.
      maxLines: 2,
      alignment: alignment,
      tooltip: DateFormat('EEEE d MMMM yyyy, HH:mm').format(local),
    );
  }

  /// The micro-label. Rendered uppercase however it is passed in.
  final String label;

  /// The value text. Null only on [DataPair.custom], where [child] takes over.
  final String? value;

  /// Arbitrary value widget, from [DataPair.custom].
  final Widget? child;

  final bool mono;
  final DataEmphasis emphasis;
  final Color? valueColor;

  /// A small glyph beside the *value*, never beside the label.
  final IconData? icon;

  /// Sits to the right of the whole pair — a chip, an edit affordance.
  final Widget? trailing;

  final int maxLines;
  final CrossAxisAlignment alignment;

  /// Long-press explanation. [DataPair.timestamp] fills it with the full date.
  final String? tooltip;

  /// Em dash, not "N/A" and not a blank: an operator must be able to tell "nothing was entered"
  /// from "this field failed to load".
  static const placeholder = '—';

  TextStyle _valueStyle(BuildContext context) {
    final color = valueColor ??
        (emphasis == DataEmphasis.quiet
            ? context.scheme.onSurfaceVariant
            : context.scheme.onSurface);
    if (mono) {
      return AppTheme.mono(
        size: switch (emphasis) {
          DataEmphasis.quiet => 11.5,
          DataEmphasis.normal => 13.5,
          DataEmphasis.strong => 15,
          DataEmphasis.display => 20,
        },
        weight: switch (emphasis) {
          DataEmphasis.quiet || DataEmphasis.normal => FontWeight.w500,
          DataEmphasis.strong || DataEmphasis.display => FontWeight.w600,
        },
        color: color,
      );
    }
    final text = context.text;
    final base = switch (emphasis) {
      DataEmphasis.quiet => text.bodySmall,
      DataEmphasis.normal => text.bodyLarge,
      DataEmphasis.strong => text.titleMedium,
      DataEmphasis.display => text.headlineSmall,
    };
    return (base ?? const TextStyle()).copyWith(
      color: color,
      fontWeight: emphasis == DataEmphasis.quiet ? FontWeight.w400 : FontWeight.w500,
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget labelWidget = Text(
      label.toUpperCase(),
      style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    // The trailing chip rides on the label's line, so the value keeps the full width. Beside the
    // whole pair it squeezed the value — a job's price rendered as "₹3,46,7…".
    if (trailing != null) {
      labelWidget = Row(
        children: [
          Expanded(child: labelWidget),
          const SizedBox(width: Spacing.sm),
          trailing!,
        ],
      );
    }

    Widget valuePart;
    if (child != null) {
      valuePart = child!;
    } else {
      final style = _valueStyle(context);
      final Widget textWidget = Text(
        value!.isEmpty ? placeholder : value!,
        style: style,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      );
      valuePart = icon == null
          ? textWidget
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: (style.fontSize ?? 14) + 2, color: style.color),
                const SizedBox(width: Spacing.xs + 2),
                Flexible(child: textWidget),
              ],
            );
    }

    final pair = Column(
      crossAxisAlignment: trailing != null ? CrossAxisAlignment.stretch : alignment,
      mainAxisSize: MainAxisSize.min,
      children: [
        labelWidget,
        const SizedBox(height: Spacing.xs),
        valuePart,
      ],
    );

    final message = tooltip;
    return message == null ? pair : Tooltip(message: message, child: pair);
  }
}

/// A grid of [DataPair]s with even gutters — the spec-summary block on job detail, the review
/// step and every partner brief.
///
/// [Wrap] alone cannot give equal column widths, so the item width is computed from the space
/// available. Below [minColumnWidth] the grid collapses a column at a time, which is what a
/// 360dp handset needs.
final class DataPairGrid extends StatelessWidget {
  const DataPairGrid({
    super.key,
    required this.children,
    this.columns = 2,
    this.spacing = Spacing.md,
    this.runSpacing = Spacing.md,
    this.minColumnWidth = 148,
  });

  final List<Widget> children;
  final int columns;
  final double spacing;
  final double runSpacing;
  final double minColumnWidth;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final available =
            constraints.maxWidth.isFinite ? constraints.maxWidth : minColumnWidth;
        var count = columns;
        while (count > 1 && (available - spacing * (count - 1)) / count < minColumnWidth) {
          count--;
        }
        final itemWidth = (available - spacing * (count - 1)) / count;
        return Wrap(
          spacing: spacing,
          runSpacing: runSpacing,
          children: [
            for (final child in children) SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }
}
