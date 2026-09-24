/// D-004 — money is an integer count of minor units plus an ISO-4217 code. Never a double.
///
/// Every money field in all 46 mockups was a hardcoded USD string with no currency selector,
/// while the manufacturer is an Indian entity. Two consequences are handled here: the Indian
/// digit grouping (lakh/crore), and the fact that INR and USD both have 2 minor digits but
/// other currencies do not.
library;

import 'package:intl/intl.dart';

/// An exact monetary amount. `minor` is paise for INR, cents for USD.
final class Money implements Comparable<Money> {
  const Money(this.minor, this.currency);

  const Money.inr(this.minor) : currency = 'INR';
  const Money.usd(this.minor) : currency = 'USD';

  /// Parse operator input: "4,850.50" -> 485050 minor units.
  factory Money.parse(String input, String currency) {
    final cleaned = input.replaceAll(RegExp(r'[^0-9.\-]'), '');
    if (cleaned.isEmpty) return Money(0, currency);
    final value = double.tryParse(cleaned) ?? 0;
    return Money((value * _scale(currency)).round(), currency);
  }

  final int minor;
  final String currency;

  static const zeroInr = Money.inr(0);

  static int _scale(String currency) => switch (currency) {
        'JPY' || 'KRW' => 1,
        'BHD' || 'KWD' || 'OMR' => 1000,
        _ => 100,
      };

  static int _digits(String currency) => switch (_scale(currency)) {
        1 => 0,
        1000 => 3,
        _ => 2,
      };

  double get major => minor / _scale(currency);

  bool get isZero => minor == 0;
  bool get isNegative => minor < 0;

  Money operator +(Money other) {
    _assertSame(other);
    return Money(minor + other.minor, currency);
  }

  Money operator -(Money other) {
    _assertSame(other);
    return Money(minor - other.minor, currency);
  }

  /// Multiply by a quantity. Rounds half-away-from-zero, the convention an invoice expects.
  Money operator *(num factor) => Money((minor * factor).round(), currency);

  Money percent(num pct) => Money((minor * pct / 100).round(), currency);

  void _assertSame(Money other) {
    if (other.currency != currency) {
      throw ArgumentError('Cannot combine $currency with ${other.currency}');
    }
  }

  /// `₹4,85,000.00` for INR (Indian grouping), `$4,850.00` otherwise.
  String format({bool compact = false, bool symbol = true}) {
    if (currency == 'INR') return _formatInr(compact: compact, symbol: symbol);
    final f = NumberFormat.currency(
      locale: 'en_US',
      symbol: symbol ? _symbolFor(currency) : '',
      decimalDigits: compact ? 0 : _digits(currency),
    );
    return f.format(major).trim();
  }

  /// Indian grouping puts the first separator after three digits and every two after that:
  /// 4850000 -> 48,50,000. `NumberFormat('en_IN')` does this correctly.
  String _formatInr({required bool compact, required bool symbol}) {
    final f = NumberFormat.currency(
      locale: 'en_IN',
      symbol: symbol ? '₹' : '',
      decimalDigits: compact ? 0 : 2,
    );
    return f.format(major).trim();
  }

  static String _symbolFor(String code) => switch (code) {
        'INR' => '₹',
        'USD' => r'$',
        'EUR' => '€',
        'GBP' => '£',
        'AED' => 'AED ',
        _ => '$code ',
      };

  @override
  int compareTo(Money other) {
    _assertSame(other);
    return minor.compareTo(other.minor);
  }

  @override
  bool operator ==(Object other) =>
      other is Money && other.minor == minor && other.currency == currency;

  @override
  int get hashCode => Object.hash(minor, currency);

  @override
  String toString() => format();
}

/// D-004 — GST. Jewellery is HSN 7113 at 3%; making charges are 5%.
/// Interstate supply is IGST; intrastate splits into CGST + SGST.
final class GstBreakdown {
  const GstBreakdown({
    required this.taxable,
    required this.cgst,
    required this.sgst,
    required this.igst,
  });

  factory GstBreakdown.on(
    Money taxable, {
    required double ratePct,
    required bool interstate,
  }) {
    final total = taxable.percent(ratePct);
    if (interstate) {
      return GstBreakdown(
        taxable: taxable,
        cgst: Money(0, taxable.currency),
        sgst: Money(0, taxable.currency),
        igst: total,
      );
    }
    // Split half each, giving any odd minor unit to CGST so the parts always sum to total.
    final half = Money(total.minor ~/ 2, taxable.currency);
    final remainder = Money(total.minor - half.minor, taxable.currency);
    return GstBreakdown(
      taxable: taxable,
      cgst: remainder,
      sgst: half,
      igst: Money(0, taxable.currency),
    );
  }

  final Money taxable;
  final Money cgst;
  final Money sgst;
  final Money igst;

  Money get tax => cgst + sgst + igst;
  Money get total => taxable + tax;
}

/// Standard rates for the trade. Kept here so an invoice never hardcodes a number.
abstract final class GstRates {
  /// HSN 7113 — articles of jewellery of precious metal.
  static const jewellery = 3.0;

  /// Job work / making charges.
  static const makingCharges = 5.0;

  /// Certification and other services.
  static const services = 18.0;

  static double forCategory(String category) => switch (category) {
        'metal' || 'gemstones' => jewellery,
        'labor' || 'setting' => makingCharges,
        'certification' => services,
        _ => jewellery,
      };
}
