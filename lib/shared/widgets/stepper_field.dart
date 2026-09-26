/// The −/+ numeric stepper, with a centre field that can also be typed into.
///
/// Fixed from the source: the mockups shipped steppers for stone count, carat weight and ring size
/// with **zero JavaScript** — the buttons were painted, the number never moved. This one moves,
/// clamps to [min]/[max], honours a fractional [step] (carat goes in hundredths, ring size in
/// quarters), and repeats on hold so setting 24 accent stones is not 24 taps.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/shared/widgets/reduced_motion.dart';

final class StepperField extends StatefulWidget {
  const StepperField({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 999,
    this.step = 1,
    this.decimals = 0,
    this.label,
    this.unit,
    this.helperText,
    this.enabled = true,
    this.editable = true,
    this.trailing,
  })  : assert(max > min, 'max must exceed min'),
        assert(step > 0, 'step must be positive'),
        assert(decimals >= 0 && decimals <= 3);

  /// Whole counts — stones, prongs, pieces.
  factory StepperField.count({
    Key? key,
    required int value,
    required ValueChanged<int> onChanged,
    int min = 0,
    int max = 999,
    int step = 1,
    String? label,
    String? unit,
    String? helperText,
    bool enabled = true,
    Widget? trailing,
  }) =>
      StepperField(
        key: key,
        value: value.toDouble(),
        onChanged: (v) => onChanged(v.round()),
        min: min.toDouble(),
        max: max.toDouble(),
        step: step.toDouble(),
        label: label,
        unit: unit,
        helperText: helperText,
        enabled: enabled,
        trailing: trailing,
      );

  /// Carat weight — two decimals, hundredth steps, which is how a stone is actually quoted.
  factory StepperField.carat({
    Key? key,
    required double value,
    required ValueChanged<double> onChanged,
    double min = 0,
    double max = 30,
    String label = 'Carat Weight',
    bool enabled = true,
    String? helperText,
    Widget? trailing,
  }) =>
      StepperField(
        key: key,
        value: value,
        onChanged: onChanged,
        min: min,
        max: max,
        step: 0.01,
        decimals: 2,
        label: label,
        unit: 'ct',
        helperText: helperText,
        enabled: enabled,
        trailing: trailing,
      );

  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final double step;

  /// Decimal places shown and kept. 0 for counts, 2 for carats and grams, 2 for millimetres.
  final int decimals;

  final String? label;

  /// Rendered after the number in the mono face — `ct`, `g`, `mm`. Use the [Uom] symbols.
  final String? unit;

  final String? helperText;
  final bool enabled;

  /// When false the centre is read-only and only the buttons move the number.
  final bool editable;

  /// A `ReqTag` for the label row.
  final Widget? trailing;

  @override
  State<StepperField> createState() => _StepperFieldState();
}

class _StepperFieldState extends State<StepperField> {
  late final TextEditingController _controller =
      TextEditingController(text: _format(widget.value));
  final _focus = FocusNode();
  Timer? _repeat;

  String _format(double v) => v.toStringAsFixed(widget.decimals);

  double _clamp(double v) {
    final clamped = v.clamp(widget.min, widget.max);
    // Round to the field's precision so repeated 0.01 steps cannot drift into 0.7000000000001.
    final factor = <int, double>{0: 1, 1: 10, 2: 100, 3: 1000}[widget.decimals]!;
    return (clamped * factor).round() / factor;
  }

  @override
  void didUpdateWidget(StepperField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _format(widget.value) != _controller.text) {
      _controller.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _repeat?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _nudge(int direction) {
    final next = _clamp(widget.value + widget.step * direction);
    if (next == widget.value) return;
    _controller.text = _format(next);
    HapticFeedback.selectionClick();
    widget.onChanged(next);
  }

  /// Hold to repeat: a short delay, then four steps a second, accelerating after a second of
  /// holding. Long-press cancels itself on release or on dispose.
  void _startRepeat(int direction) {
    _repeat?.cancel();
    var ticks = 0;
    _repeat = Timer.periodic(const Duration(milliseconds: 90), (_) {
      ticks++;
      final multiplier = ticks > 22 ? 10 : (ticks > 10 ? 3 : 1);
      for (var i = 0; i < multiplier; i++) {
        _nudge(direction);
      }
    });
  }

  void _stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
  }

  void _commitTyped(String text) {
    final parsed = double.tryParse(text.replaceAll(RegExp(r'[^0-9.\-]'), ''));
    final next = _clamp(parsed ?? widget.value);
    _controller.text = _format(next);
    if (next != widget.value) widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final canDecrease = widget.enabled && widget.value > widget.min;
    final canIncrease = widget.enabled && widget.value < widget.max;

    final centre = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: widget.editable && widget.enabled
              ? TextField(
                  controller: _controller,
                  focusNode: _focus,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: widget.decimals > 0,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      widget.decimals > 0 ? RegExp(r'[0-9.]') : RegExp(r'[0-9]'),
                    ),
                  ],
                  style: AppTheme.mono(
                    size: 18,
                    weight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                  decoration: const InputDecoration(
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onTapOutside: (_) => _focus.unfocus(),
                  onEditingComplete: () {
                    _commitTyped(_controller.text);
                    _focus.unfocus();
                  },
                  onSubmitted: _commitTyped,
                )
              : Text(
                  _format(widget.value),
                  textAlign: TextAlign.center,
                  style: AppTheme.mono(
                    size: 18,
                    weight: FontWeight.w600,
                    color: widget.enabled ? scheme.onSurface : scheme.onSurfaceVariant,
                  ),
                ),
        ),
        if (widget.unit != null) ...[
          const SizedBox(width: Spacing.xs + 2),
          Text(
            widget.unit!,
            style: AppTheme.mono(size: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );

    final control = Container(
      height: 52,
      decoration: BoxDecoration(
        color: dh.surfaceContainerLow,
        borderRadius: Radii.rMd,
        border: Border.all(color: dh.outlineVariant),
      ),
      child: Row(
        children: [
          _StepButton(
            icon: Icons.remove_rounded,
            enabled: canDecrease,
            semanticLabel: 'Decrease',
            onTap: () => _nudge(-1),
            onHoldStart: () => _startRepeat(-1),
            onHoldEnd: _stopRepeat,
          ),
          Expanded(child: centre),
          _StepButton(
            icon: Icons.add_rounded,
            enabled: canIncrease,
            semanticLabel: 'Increase',
            onTap: () => _nudge(1),
            onHoldStart: () => _startRepeat(1),
            onHoldEnd: _stopRepeat,
          ),
        ],
      ),
    );

    if (widget.label == null && widget.helperText == null) return control;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.label!.toUpperCase(),
                  style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
          const SizedBox(height: Spacing.sm),
        ],
        control,
        if (widget.helperText != null) ...[
          const SizedBox(height: Spacing.xs + 2),
          Text(
            widget.helperText!,
            style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

final class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.enabled,
    required this.semanticLabel,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  final IconData icon;
  final bool enabled;
  final String semanticLabel;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      excludeSemantics: true,
      child: GestureDetector(
        onLongPressStart: enabled ? (_) => onHoldStart() : null,
        onLongPressEnd: enabled ? (_) => onHoldEnd() : null,
        onLongPressCancel: enabled ? onHoldEnd : null,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: Radii.rMd,
          // A 52x52 target: the shop floor taps this with gloves on.
          child: AnimatedContainer(
            duration: context.motion(Motion.fast),
            width: 52,
            height: 52,
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 22,
              color: enabled ? scheme.onSurface : dh.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }
}
