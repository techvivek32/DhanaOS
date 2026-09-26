/// Ring size, Indian scale, with the US and UK equivalents shown rather than assumed.
///
/// D-012: `engagement_ring_specs_expanded` labelled this "(India)" and its sibling labelled the
/// same control "(US)". Neither converted, and neither stored which scale it meant. A ring cut two
/// Indian sizes out is a remake, so this control makes the scale unmistakable: the chips are Indian
/// sizes, and the line under them reads back the US number, the UK letter and the inner diameter
/// the mandrel will show.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/features/intake/ring_sizes.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';

final class RingSizeField extends StatelessWidget {
  const RingSizeField({
    super.key,
    required this.india,
    required this.onChanged,
    this.onCleared,
  });

  /// The stored Indian size. `product_specs.ring_size_in` is numeric(4,1), so a half size is
  /// representable — but the Indian scale is whole numbers, and this picker keeps it that way.
  final double? india;
  final ValueChanged<RingSize> onChanged;
  final VoidCallback? onCleared;

  int? get _selected => india?.round();

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final row = RingSizes.byIndia(selected);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChoiceWrap<int>(
          mono: true,
          values: RingSizes.commonIndia,
          selected: RingSizes.commonIndia.contains(selected) ? selected : null,
          labelOf: (value) => 'IN $value',
          onSelected: (value) {
            final picked = RingSizes.byIndia(value);
            if (picked != null) onChanged(picked);
          },
        ),
        const Gap.sm(),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _openChart(context),
                icon: const Icon(Icons.straighten_rounded, size: 18),
                label: Text(
                  row == null || RingSizes.commonIndia.contains(selected)
                      ? 'Full size chart (1–30)'
                      : 'IN $selected — change',
                ),
              ),
            ),
            if (onCleared != null && selected != null) ...[
              const SizedBox(width: Spacing.sm),
              IconButton(
                onPressed: onCleared,
                tooltip: 'Clear the ring size',
                icon: const Icon(Icons.backspace_outlined),
              ),
            ],
          ],
        ),
        const Gap.sm(),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm + Spacing.xs,
            vertical: Spacing.sm,
          ),
          decoration: BoxDecoration(
            color: context.dh.surfaceContainerLow,
            borderRadius: Radii.rMd,
            border: Border.all(color: context.dh.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(
                Icons.swap_horiz_rounded,
                size: 16,
                color: context.scheme.onSurfaceVariant,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  RingSizes.conversionLabel(selected),
                  style: AppTheme.mono(size: 12.5, color: context.scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openChart(BuildContext context) async {
    final picked = await showModalBottomSheet<RingSize>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.85,
        child: _ChartSheet(selected: _selected),
      ),
    );
    if (picked != null) onChanged(picked);
  }
}

final class _ChartSheet extends StatelessWidget {
  const _ChartSheet({this.selected});

  final int? selected;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Ring size chart',
            style: context.text.headlineSmall?.copyWith(color: scheme.onSurface),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            'India is what we cut to. US, UK and the inner diameter are here so you can read a '
            'customer\'s number back in whatever scale they quoted.',
            style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const Gap.md(),
          Row(
            children: [
              _HeadCell('INDIA', flex: 3),
              _HeadCell('US', flex: 3),
              _HeadCell('UK', flex: 3),
              _HeadCell('INNER Ø', flex: 4),
            ],
          ),
          const Divider(),
          Expanded(
            child: ListView.separated(
              itemCount: RingSizes.chart.length,
              separatorBuilder: (_, __) => Divider(color: context.dh.outlineVariant),
              itemBuilder: (itemContext, index) {
                final row = RingSizes.chart[index];
                final isSelected = row.india == selected;
                return InkWell(
                  onTap: () => Navigator.of(itemContext).pop(row),
                  child: Container(
                    color: isSelected
                        ? itemContext.scheme.secondaryContainer
                        : Colors.transparent,
                    padding: const EdgeInsets.symmetric(vertical: Spacing.sm + 2),
                    child: Row(
                      children: [
                        _Cell('${row.india}', flex: 3, strong: true, selected: isSelected),
                        _Cell(
                          RingSize.usLabel(row.us),
                          flex: 3,
                          selected: isSelected,
                        ),
                        _Cell(row.uk, flex: 3, selected: isSelected),
                        _Cell(
                          '${row.diameterMm.toStringAsFixed(2)} mm',
                          flex: 4,
                          selected: isSelected,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

final class _HeadCell extends StatelessWidget {
  const _HeadCell(this.text, {required this.flex});

  final String text;
  final int flex;

  @override
  Widget build(BuildContext context) => Expanded(
        flex: flex,
        child: Text(
          text,
          style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
        ),
      );
}

final class _Cell extends StatelessWidget {
  const _Cell(
    this.text, {
    required this.flex,
    this.strong = false,
    this.selected = false,
  });

  final String text;
  final int flex;
  final bool strong;
  final bool selected;

  @override
  Widget build(BuildContext context) => Expanded(
        flex: flex,
        child: Text(
          text,
          style: AppTheme.mono(
            size: 13,
            weight: strong ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? context.scheme.onSecondaryContainer
                : context.scheme.onSurface,
          ),
        ),
      );
}
