/// The amount in words, in the Indian scale.
///
/// A GST tax invoice carries the total spelled out — "Rupees Four Lakh Ninety-Nine Thousand Five
/// Hundred Fifty and Fifty Paise Only" — and it is not decoration: the words are what a bank and a
/// tax officer read when the digits are smudged or disputed. Every money figure in all 46 mockups
/// was a hardcoded USD string, so nothing in the corpus could produce this at all.
///
/// The scale is the Indian one for INR — crore, lakh, thousand — because that is the scale the
/// digits are grouped in (D-004: `48,50,000`, not `4,850,000`). Other currencies fall back to the
/// short scale, so a USD invoice reads "million" rather than "ten lakh".
library;

import 'package:dhanaos/core/money.dart';

/// 'Rupees four lakh ninety-nine thousand five hundred fifty and fifty paise only'.
///
/// Rendered with a leading capital and nothing else capitalised, which is how the phrase reads on
/// a printed invoice without shouting.
String amountInWords(Money money) {
  final scale = _minorScale(money.currency);
  final minor = money.minor.abs();
  final whole = minor ~/ scale;
  final fraction = minor % scale;
  final names = _CurrencyNames.of(money.currency);
  final indian = money.currency == 'INR';

  final wholeWords = indian ? _indianWhole(whole) : _westernWhole(whole);

  final parts = <String>[
    if (money.isNegative) 'minus',
    names.majorFor(whole),
    wholeWords,
    if (fraction > 0) ...[
      'and',
      indian ? _indianWhole(fraction) : _westernWhole(fraction),
      names.minorFor(fraction),
    ],
    'only',
  ];

  final sentence = parts.join(' ');
  return sentence.isEmpty
      ? sentence
      : sentence[0].toUpperCase() + sentence.substring(1);
}

/// How many minor units make one major unit.
///
/// Duplicated from `core/money.dart`, whose own scale table is private. Two currencies here are
/// not the same two as everywhere else in the app by accident — this is the same list, and it has
/// to move with it.
int _minorScale(String currency) => switch (currency) {
      'JPY' || 'KRW' => 1,
      'BHD' || 'KWD' || 'OMR' => 1000,
      _ => 100,
    };

/// Singular and plural, because "one rupee and one paisa" is what a one-rupee invoice says.
final class _CurrencyNames {
  const _CurrencyNames(this.major, this.majorPlural, this.minor, this.minorPlural);

  final String major;
  final String majorPlural;
  final String minor;
  final String minorPlural;

  static _CurrencyNames of(String currency) => switch (currency) {
        'INR' => const _CurrencyNames('rupee', 'rupees', 'paisa', 'paise'),
        'USD' => const _CurrencyNames('dollar', 'dollars', 'cent', 'cents'),
        'EUR' => const _CurrencyNames('euro', 'euros', 'cent', 'cents'),
        'GBP' => const _CurrencyNames('pound', 'pounds', 'penny', 'pence'),
        'AED' => const _CurrencyNames('dirham', 'dirhams', 'fils', 'fils'),
        _ => _CurrencyNames(currency, currency, 'cent', 'cents'),
      };

  String majorFor(int count) => count == 1 ? major : majorPlural;

  String minorFor(int count) => count == 1 ? minor : minorPlural;
}

const _units = <String>[
  'zero',
  'one',
  'two',
  'three',
  'four',
  'five',
  'six',
  'seven',
  'eight',
  'nine',
  'ten',
  'eleven',
  'twelve',
  'thirteen',
  'fourteen',
  'fifteen',
  'sixteen',
  'seventeen',
  'eighteen',
  'nineteen',
];

const _tens = <String>[
  '',
  '',
  'twenty',
  'thirty',
  'forty',
  'fifty',
  'sixty',
  'seventy',
  'eighty',
  'ninety',
];

String _below100(int n) {
  if (n < 20) return _units[n];
  final tens = _tens[n ~/ 10];
  final unit = n % 10;
  return unit == 0 ? tens : '$tens-${_units[unit]}';
}

String _below1000(int n) {
  if (n < 100) return _below100(n);
  final hundreds = n ~/ 100;
  final rest = n % 100;
  final head = '${_units[hundreds]} hundred';
  return rest == 0 ? head : '$head ${_below100(rest)}';
}

/// Crore, lakh, thousand — the grouping the digits already use.
String _indianWhole(int n) {
  if (n == 0) return _units[0];

  var remaining = n;
  final crore = remaining ~/ 10000000;
  remaining %= 10000000;
  final lakh = remaining ~/ 100000;
  remaining %= 100000;
  final thousand = remaining ~/ 1000;
  remaining %= 1000;

  return <String>[
    // Above ninety-nine crore the scale repeats — "one hundred crore" — which is exactly how it
    // is said, so the recursion is the correct answer rather than a shortcut.
    if (crore > 0) '${_indianWhole(crore)} crore',
    if (lakh > 0) '${_below1000(lakh)} lakh',
    if (thousand > 0) '${_below1000(thousand)} thousand',
    if (remaining > 0) _below1000(remaining),
  ].join(' ');
}

/// Short scale, for a USD or EUR invoice.
String _westernWhole(int n) {
  if (n == 0) return _units[0];

  var remaining = n;
  final billion = remaining ~/ 1000000000;
  remaining %= 1000000000;
  final million = remaining ~/ 1000000;
  remaining %= 1000000;
  final thousand = remaining ~/ 1000;
  remaining %= 1000;

  return <String>[
    if (billion > 0) '${_below1000(billion)} billion',
    if (million > 0) '${_below1000(million)} million',
    if (thousand > 0) '${_below1000(thousand)} thousand',
    if (remaining > 0) _below1000(remaining),
  ].join(' ');
}
