/// India → US → UK ring sizing, as a table rather than a formula.
///
/// D-012: `engagement_ring_specs_expanded` labelled its field "(India)" while its sibling screen
/// labelled the same control "(US)", and neither converted. For an Indian workshop that takes
/// orders from US and UK retailers, that ambiguity is a remake. India is primary here; US and UK
/// are shown beside it so an operator can read the customer's number back in whichever scale they
/// quoted it in.
///
/// The three scales are not linearly related, so this is a lookup, not arithmetic: the Indian
/// scale steps ~0.4 mm of inner diameter, the US scale ~0.41 mm from a different origin, and the
/// UK scale is lettered in half steps. Interpolating between them would put a ring a quarter size
/// out, which on a finger is the difference between "snug" and "lost down a drain".
library;

/// One row of the conversion chart.
final class RingSize {
  const RingSize(this.india, this.us, this.uk, this.diameterMm);

  /// Indian scale, 1–30.
  final int india;

  /// US / Canada numeric scale.
  final double us;

  /// UK / Australia letter scale.
  final String uk;

  /// Inner diameter. The only figure that is physically true; the rest are conventions over it.
  final double diameterMm;

  /// Inner circumference — what a sizing strip measures.
  double get circumferenceMm => diameterMm * 3.141592653589793;

  /// 'IN 14 · US 7 · UK N½'
  String get label => 'IN $india · US ${usLabel(us)} · UK $uk';

  /// '17.35 mm Ø'
  String get diameterLabel => '${diameterMm.toStringAsFixed(2)} mm Ø';

  /// '7', '7.5' — never '7.00'. A trailing zero on a ring size reads as a precision the scale
  /// does not have.
  static String usLabel(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  }
}

/// The chart. Indian sizes 1–30 with their US equivalents, UK letters and inner diameters.
abstract final class RingSizes {
  static const chart = <RingSize>[
    RingSize(1, 1.0, 'B½', 12.37),
    RingSize(2, 1.5, 'C½', 12.78),
    RingSize(3, 2.0, 'D½', 13.21),
    RingSize(4, 2.5, 'E½', 13.61),
    RingSize(5, 3.0, 'F½', 14.07),
    RingSize(6, 3.25, 'G', 14.36),
    RingSize(7, 3.75, 'G½', 14.86),
    RingSize(8, 4.25, 'H½', 15.27),
    RingSize(9, 5.0, 'J½', 15.70),
    RingSize(10, 5.5, 'K½', 16.10),
    RingSize(11, 6.0, 'L½', 16.51),
    RingSize(12, 6.5, 'M½', 16.92),
    RingSize(13, 7.0, 'N½', 17.35),
    RingSize(14, 7.5, 'O½', 17.75),
    RingSize(15, 8.0, 'P½', 18.19),
    RingSize(16, 8.5, 'Q½', 18.53),
    RingSize(17, 9.0, 'R½', 19.00),
    RingSize(18, 9.5, 'S½', 19.41),
    RingSize(19, 10.0, 'T½', 19.84),
    RingSize(20, 10.5, 'U½', 20.20),
    RingSize(21, 11.0, 'V½', 20.68),
    RingSize(22, 11.5, 'W½', 21.08),
    RingSize(23, 12.0, 'X½', 21.49),
    RingSize(24, 12.5, 'Y', 21.89),
    RingSize(25, 13.0, 'Z', 22.33),
    RingSize(26, 13.5, 'Z+1', 22.71),
    RingSize(27, 14.0, 'Z+2', 23.11),
    RingSize(28, 14.5, 'Z+3', 23.55),
    RingSize(29, 15.0, 'Z+4', 23.93),
    RingSize(30, 15.5, 'Z+5', 24.36),
  ];

  /// The sizes an engagement or wedding ring is actually cut at, offered first in the picker.
  /// The full chart stays reachable — a signet ring for a large hand is a real order.
  static const commonIndia = <int>[9, 10, 11, 12, 13, 14, 15, 16, 17, 18];

  static RingSize? byIndia(int? india) {
    if (india == null) return null;
    for (final row in chart) {
      if (row.india == india) return row;
    }
    return null;
  }

  /// Nearest Indian size to a US number, for a customer who quoted US. Never guesses beyond the
  /// chart: a US 20 comes back as the largest row rather than as an extrapolation.
  static RingSize nearestToUs(double us) {
    var best = chart.first;
    var gap = (best.us - us).abs();
    for (final row in chart) {
      final d = (row.us - us).abs();
      if (d < gap) {
        best = row;
        gap = d;
      }
    }
    return best;
  }

  /// 'US 7 · UK N½ · 17.35 mm Ø' — the conversion strip shown under the India selector.
  static String conversionLabel(int? india) {
    final row = byIndia(india);
    if (row == null) return 'Pick an Indian size to see the US and UK equivalents.';
    return 'US ${RingSize.usLabel(row.us)} · UK ${row.uk} · ${row.diameterLabel}';
  }
}
