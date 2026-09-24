/// Shared numeric formatting for the physical quantities the models expose.
///
/// Convention 5 renders every weight, carat and dimension in `AppTheme.mono()` so operators can
/// compare digits down a column. That only works if the digits themselves are consistent: a
/// Postgres `numeric(8,3)` arrives as `8.5` or `8.500` depending on how it was written, and two
/// spellings of one weight in the same column defeat the point of the mono column.
library;

/// Drops a trailing fractional zero run: `14.0` -> `14`, `6.50` -> `6.5`, `0.05` -> `0.05`.
String trimDecimal(double value, {int maxDigits = 2}) {
  final s = value.toStringAsFixed(maxDigits);
  if (!s.contains('.')) return s;
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// `8.5 g`. Grams carry 3 decimals in the schema but 2 is all a bench scale resolves.
String gramLabel(double? grams, {int maxDigits = 2}) =>
    grams == null ? '—' : '${trimDecimal(grams, maxDigits: maxDigits)} g';

/// `1.25 ct`.
String caratLabel(double? carat) => carat == null ? '—' : '${trimDecimal(carat)} ct';

/// `1.5 mm`.
String mmLabel(double? mm) => mm == null ? '—' : '${trimDecimal(mm)} mm';

/// `± 0.5 g` — always signed, because a tolerance without its sign reads as a weight.
String toleranceLabel(double? tolerance) =>
    tolerance == null ? '' : '± ${trimDecimal(tolerance)} g';

/// `1.2–1.5 mm`, collapsing to one figure when both bounds match or only one was given.
String mmRangeLabel(double? min, double? max) {
  if (min == null && max == null) return '—';
  if (min != null && max != null) {
    if (min == max) return mmLabel(min);
    return '${trimDecimal(min)}–${trimDecimal(max)} mm';
  }
  return mmLabel(min ?? max);
}

/// `6.50 × 6.45 × 4.02 mm` — a stone's L × W × D. `refined_inputs` split the mockup's vague
/// single "Dimensions (L x W x D mm)" text field into three discrete numbers; this puts them
/// back together for display only.
String dimensionsLabel(double? length, double? width, double? depth) {
  final parts = [length, width, depth].whereType<double>().map(trimDecimal).toList();
  return parts.isEmpty ? '—' : '${parts.join(' × ')} mm';
}
