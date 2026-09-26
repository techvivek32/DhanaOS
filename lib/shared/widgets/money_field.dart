/// A money input bound to [Money] — integer minor units in, integer minor units out.
///
/// D-004: every money field in all 46 mockups was a hardcoded USD string with no currency
/// selector, while the manufacturer is an Indian entity. Two consequences show up here. First, the
/// grouping: 485000000 paise is `48,50,000.00`, not `4,850,000.00` — Indian grouping breaks after
/// three digits and every two after that, and an operator in Surat will read a western-grouped
/// figure wrong. Second, [onCurrencyChanged]: pass it and the prefix becomes a real selector
/// instead of a painted symbol.
///
/// The widget never holds a double. Text is parsed straight to minor units through [Money.parse],
/// so `4,850.50` becomes `485050` with no float in the path.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';

final class MoneyField extends StatefulWidget {
  const MoneyField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.hint,
    this.helperText,
    this.errorText,
    this.enabled = true,
    this.autofocus = false,
    this.focusNode,
    this.textInputAction,
    this.onSubmitted,
    this.currencies = const ['INR', 'USD'],
    this.onCurrencyChanged,
    this.maxMinor,
    this.trailing,
    this.alignRight = false,
  });

  final Money value;
  final ValueChanged<Money> onChanged;

  /// Uppercase micro-label above the field, matching the `DataPair` idiom. Prefer it over a
  /// floating label so a form of money fields reads as a column.
  final String? label;

  final String? hint;
  final String? helperText;
  final String? errorText;
  final bool enabled;
  final bool autofocus;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final ValueChanged<Money>? onSubmitted;

  /// Offered in the prefix selector when [onCurrencyChanged] is set. D-004: INR primary,
  /// USD supported.
  final List<String> currencies;

  /// Supply this to let the operator switch currency. Without it the prefix is a plain symbol.
  final ValueChanged<String>? onCurrencyChanged;

  /// Upper bound in minor units. Typing past it clamps rather than silently accepting a figure
  /// the quote cannot carry.
  final int? maxMinor;

  /// A `ReqTag` or unit hint placed on the label row.
  final Widget? trailing;

  /// Right-aligns the figure. Use it when the field sits in a column of totals.
  final bool alignRight;

  /// The currency symbol, derived from [Money] itself so the mapping lives in exactly one place.
  static String symbolOf(String currency) => _symbolCache.putIfAbsent(currency, () {
        final rendered = Money(0, currency).format(compact: true);
        return rendered.replaceAll(RegExp(r'[\d., \s]'), '');
      });

  static final Map<String, String> _symbolCache = {};

  @override
  State<MoneyField> createState() => _MoneyFieldState();
}

class _MoneyFieldState extends State<MoneyField> {
  late final TextEditingController _controller =
      TextEditingController(text: _display(widget.value));
  late String _currency = widget.value.currency;

  /// Formats a [Money] for editing: grouped, no symbol, and with a bare `.00` dropped so the
  /// caret does not land behind two zeros the operator never typed.
  static String _display(Money m) {
    if (m.isZero) return '';
    final full = m.format(symbol: false);
    final trimmed = full.replaceFirst(RegExp(r'\.0+$'), '');
    return trimmed.isEmpty ? full : trimmed;
  }

  @override
  void didUpdateWidget(MoneyField old) {
    super.didUpdateWidget(old);
    final currencyChanged = widget.value.currency != _currency;
    if (currencyChanged) _currency = widget.value.currency;

    // Only rewrite the field when the parent's value genuinely disagrees with what is on screen.
    // Comparing the *parsed* text, not the text itself, is what stops this fighting the operator
    // mid-keystroke: "4,8" and "48" parse the same, so neither triggers a reset.
    final onScreen = Money.parse(_controller.text, _currency);
    if (currencyChanged || onScreen != widget.value) {
      _controller.value = TextEditingValue(
        text: _display(widget.value),
        selection: TextSelection.collapsed(offset: _display(widget.value).length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleText(String text) {
    var money = Money.parse(text, _currency);
    final cap = widget.maxMinor;
    if (cap != null && money.minor > cap) {
      money = Money(cap, _currency);
      final clamped = _display(money);
      _controller.value = TextEditingValue(
        text: clamped,
        selection: TextSelection.collapsed(offset: clamped.length),
      );
    }
    widget.onChanged(money);
  }

  Widget _prefix(BuildContext context) {
    final symbol = MoneyField.symbolOf(_currency);
    final style = AppTheme.mono(
      size: 15,
      weight: FontWeight.w600,
      color: widget.enabled ? context.scheme.onSurface : context.scheme.onSurfaceVariant,
    );

    if (widget.onCurrencyChanged == null || !widget.enabled) {
      return Padding(
        padding: const EdgeInsets.only(left: Spacing.md, right: Spacing.sm),
        child: Text(symbol, style: style),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: Spacing.sm, right: Spacing.xs),
      child: PopupMenuButton<String>(
        tooltip: 'Change currency',
        initialValue: _currency,
        position: PopupMenuPosition.under,
        onSelected: (code) {
          setState(() => _currency = code);
          widget.onCurrencyChanged!(code);
          // Re-emit in the new currency so the parent's Money never carries a stale code.
          widget.onChanged(Money(Money.parse(_controller.text, code).minor, code));
        },
        itemBuilder: (context) => [
          for (final code in widget.currencies)
            PopupMenuItem(
              value: code,
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(MoneyField.symbolOf(code), style: AppTheme.mono(size: 14)),
                  ),
                  Text(code, style: context.text.bodyMedium),
                ],
              ),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: Spacing.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(symbol, style: style),
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 18,
                color: context.scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: _controller,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      focusNode: widget.focusNode,
      textInputAction: widget.textInputAction,
      textAlign: widget.alignRight ? TextAlign.right : TextAlign.start,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: AppTheme.mono(size: 16, weight: FontWeight.w600, color: context.scheme.onSurface),
      inputFormatters: [MoneyInputFormatter(_currency)],
      onChanged: _handleText,
      onSubmitted: (text) => widget.onSubmitted?.call(Money.parse(text, _currency)),
      decoration: InputDecoration(
        hintText: widget.hint ?? '0',
        hintStyle: AppTheme.mono(size: 16, color: context.scheme.onSurfaceVariant),
        errorText: widget.errorText,
        helperText: widget.helperText,
        prefixIcon: _prefix(context),
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.md - 2,
        ),
      ),
    );

    if (widget.label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.label!.toUpperCase(),
                style: context.text.labelSmall
                    ?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
            ),
            if (widget.trailing != null) widget.trailing!,
          ],
        ),
        const SizedBox(height: Spacing.sm),
        field,
      ],
    );
  }
}

/// Groups digits as the operator types, per currency convention.
///
/// INR uses the lakh/crore pattern — three digits, then pairs: `1,23,45,678`. Everything else
/// groups in threes. Fraction digits are capped at the currency's real precision, so a JPY field
/// cannot take a decimal point at all and a BHD field takes three places.
final class MoneyInputFormatter extends TextInputFormatter {
  MoneyInputFormatter(this.currency);

  final String currency;

  bool get _indian => currency == 'INR';

  int get _fractionDigits => switch (currency) {
        'JPY' || 'KRW' => 0,
        'BHD' || 'KWD' || 'OMR' => 3,
        _ => 2,
      };

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = _clean(newValue.text);
    final formatted = _group(raw);

    // Keep the caret anchored to the digit it was in front of, counting from the right, so
    // inserting a separator to the caret's left does not teleport the cursor.
    final end = newValue.selection.end.clamp(0, newValue.text.length);
    final tailDigits =
        newValue.text.substring(end).replaceAll(RegExp(r'[^0-9.]'), '').length;

    var offset = formatted.length;
    var seen = 0;
    while (offset > 0 && seen < tailDigits) {
      offset--;
      if (RegExp(r'[0-9.]').hasMatch(formatted[offset])) seen++;
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  /// Digits plus at most one decimal point, with the fraction clipped to the currency's precision.
  String _clean(String input) {
    final digitsOnly = input.replaceAll(RegExp(r'[^0-9.]'), '');
    if (_fractionDigits == 0) return digitsOnly.replaceAll('.', '');

    final firstDot = digitsOnly.indexOf('.');
    if (firstDot < 0) return digitsOnly;

    final whole = digitsOnly.substring(0, firstDot);
    final fraction =
        digitsOnly.substring(firstDot + 1).replaceAll('.', '');
    final clipped = fraction.length > _fractionDigits
        ? fraction.substring(0, _fractionDigits)
        : fraction;
    return '$whole.$clipped';
  }

  String _group(String cleaned) {
    final dot = cleaned.indexOf('.');
    final whole = dot < 0 ? cleaned : cleaned.substring(0, dot);
    final rest = dot < 0 ? '' : cleaned.substring(dot);
    if (whole.isEmpty) return rest;
    return (_indian ? _groupIndian(whole) : _groupWestern(whole)) + rest;
  }

  static String _groupWestern(String whole) {
    final out = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      final fromRight = whole.length - i;
      out.write(whole[i]);
      if (fromRight > 1 && (fromRight - 1) % 3 == 0) out.write(',');
    }
    return out.toString();
  }

  /// Last three digits, then pairs: `48,50,000`.
  static String _groupIndian(String whole) {
    if (whole.length <= 3) return whole;
    final last3 = whole.substring(whole.length - 3);
    var head = whole.substring(0, whole.length - 3);
    final pairs = <String>[];
    while (head.length > 2) {
      pairs.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) pairs.insert(0, head);
    return '${pairs.join(',')},$last3';
  }
}
