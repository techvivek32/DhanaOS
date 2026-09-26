/// A real date field.
///
/// The mockups' delivery screen drew a date as static text — "Mar 15, 2024" — with no picker, no
/// validation and no relationship to anything. A promised date is a commitment the whole rail is
/// planned backwards from, so this one has a picker, a floor, and a place to say what is wrong with
/// the date that was chosen.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';

final class DateField extends StatelessWidget {
  const DateField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.firstDate,
    required this.lastDate,
    this.helpText = 'Choose a date',
    this.emptyLabel = 'No date chosen',
    this.warning,
    this.onCleared,
  });

  final DateTime? value;
  final ValueChanged<DateTime> onChanged;

  /// Nothing before this can be picked. Pass today to make a past date impossible rather than
  /// merely wrong.
  final DateTime firstDate;
  final DateTime lastDate;
  final String helpText;
  final String emptyLabel;

  /// A sentence about the chosen date — too soon for the lead time, a public holiday, a clash.
  final String? warning;
  final VoidCallback? onCleared;

  static final _display = DateFormat('EEE d MMM yyyy');

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final chosen = value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: Radii.rMd,
          onTap: () => _pick(context),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.md - 2,
            ),
            decoration: BoxDecoration(
              color: dh.surfaceContainerLow,
              borderRadius: Radii.rMd,
              border: Border.all(
                color: warning == null ? dh.outlineVariant : scheme.error,
                width: warning == null ? 1 : 1.5,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.event_outlined,
                  size: 20,
                  color: chosen == null ? scheme.onSurfaceVariant : scheme.onSurface,
                ),
                const SizedBox(width: Spacing.sm + Spacing.xs),
                Expanded(
                  child: chosen == null
                      ? Text(
                          emptyLabel,
                          style: context.text.bodyLarge
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        )
                      : Text(
                          // Dates render monospaced with the rest of the data, so a column of
                          // them lines up.
                          _display.format(chosen.toLocal()),
                          style: AppTheme.mono(
                            size: 15,
                            weight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                ),
                if (chosen != null && onCleared != null)
                  IconButton(
                    onPressed: onCleared,
                    tooltip: 'Clear the date',
                    icon: const Icon(Icons.backspace_outlined, size: 18),
                  )
                else
                  Icon(Icons.edit_calendar_outlined, size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
        if (warning != null) ...[
          const SizedBox(height: Spacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, size: 15, color: scheme.error),
              const SizedBox(width: Spacing.xs + 2),
              Expanded(
                child: Text(
                  warning!,
                  style: context.text.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _pick(BuildContext context) async {
    final initial = value ?? firstDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(firstDate) ? firstDate : initial,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: helpText,
    );
    if (picked != null) onChanged(DateTime(picked.year, picked.month, picked.day));
  }
}
