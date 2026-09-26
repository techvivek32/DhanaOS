/// The small controls the eleven steps share.
///
/// None of these exist in the shared set because none of them is general: a wrap of enum chips
/// that reveals a text field when "Other" is picked is an intake idiom, not a design-system
/// primitive. Everything structural — cards, tiles, segmented controls, data pairs, REQ tags —
/// comes from `shared/widgets` and is composed here rather than rebuilt.
///
/// The "Other" reveal is the one that earns its keep. Every `Other` in the 46 mockups was
/// preselected and had no follow-up field, so the specification said "Other" and the bench had to
/// ring the office. [OtherDetailField] makes the follow-up part of the control.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// A labelled block inside a step: heading, optional REQ citation, optional helper line.
final class FieldBlock extends StatelessWidget {
  const FieldBlock({
    super.key,
    required this.label,
    required this.child,
    this.helper,
    this.reqCode,
    this.reqCritical = false,
    this.trailing,
  });

  final String label;
  final Widget child;
  final String? helper;

  /// D-009 — 'REQ-MAT-01'. Renders the shared [ReqTag] so the citation looks the same wherever it
  /// appears: here, on the QC checklist, on the customer's copy.
  final String? reqCode;
  final bool reqCritical;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label.toUpperCase(),
                style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            if (reqCode != null) ReqTag(code: reqCode!, critical: reqCritical),
            if (trailing != null) ...[const SizedBox(width: Spacing.sm), trailing!],
          ],
        ),
        const SizedBox(height: Spacing.sm),
        child,
        if (helper != null) ...[
          const SizedBox(height: Spacing.xs + 2),
          Text(
            helper!,
            style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

/// A wrap of single-select chips over a list of values — the workhorse of steps 4, 5, 6 and 9.
///
/// Chips rather than a dropdown because every one of these lists is short enough to read at a
/// glance, and a shop-floor operator with a loupe in one hand should not have to open a menu to
/// see the options.
final class ChoiceWrap<T> extends StatelessWidget {
  const ChoiceWrap({
    super.key,
    required this.values,
    required this.selected,
    required this.onSelected,
    required this.labelOf,
    this.enabledOf,
    this.disabledReasonOf,
    this.mono = false,
    this.allowDeselect = false,
  });

  final List<T> values;
  final T? selected;
  final ValueChanged<T> onSelected;
  final String Function(T value) labelOf;
  final bool Function(T value)? enabledOf;
  final String Function(T value)? disabledReasonOf;

  /// Grades, carats and sizes read monospaced so a column of them lines up.
  final bool mono;

  /// Tapping the selected chip again clears it. Off by default: most of these are required.
  final bool allowDeselect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: [
        for (final value in values)
          _Chip(
            label: labelOf(value),
            selected: value == selected,
            enabled: enabledOf?.call(value) ?? true,
            disabledReason: disabledReasonOf?.call(value),
            mono: mono,
            onTap: () {
              if (value == selected && !allowDeselect) return;
              onSelected(value);
            },
          ),
      ],
    );
  }
}

final class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.mono,
    required this.onTap,
    this.disabledReason,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final bool mono;
  final String? disabledReason;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    final background = selected
        ? scheme.secondary
        : (enabled ? dh.surfaceContainerLow : dh.surfaceContainerLowest);
    final foreground = selected
        ? scheme.onSecondary
        : (enabled ? scheme.onSurface : dh.outlineVariant);

    final style = mono
        ? AppTheme.mono(size: 13, weight: FontWeight.w600, color: foreground)
        : context.text.bodyMedium?.copyWith(
            color: foreground,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          );

    Widget chip = AnimatedContainer(
      duration: context.motion(Motion.fast),
      curve: context.motionCurve,
      decoration: BoxDecoration(
        color: background,
        borderRadius: Radii.rFull,
        border: Border.all(
          color: selected ? scheme.secondary : dh.outlineVariant,
          width: selected ? 1.5 : 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md - 2,
        vertical: Spacing.sm + 2,
      ),
      child: Text(label, style: style),
    );

    if (!enabled && disabledReason != null) {
      chip = Tooltip(message: disabledReason!, child: chip);
    }

    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      inMutuallyExclusiveGroup: true,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: Radii.rFull,
        child: chip,
      ),
    );
  }
}

/// A choice list that reveals a text field when the "Other" option is taken.
///
/// D-012: every `Other` in the mockups was preselected and had no follow-up. "Setting: Other" is
/// not a specification — this is what makes it one.
final class OtherDetailField extends StatefulWidget {
  const OtherDetailField({
    super.key,
    required this.visible,
    required this.value,
    required this.onChanged,
    required this.label,
    required this.hint,
  });

  final bool visible;
  final String? value;
  final ValueChanged<String> onChanged;
  final String label;
  final String hint;

  @override
  State<OtherDetailField> createState() => _OtherDetailFieldState();
}

class _OtherDetailFieldState extends State<OtherDetailField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value ?? '');
  final _focus = FocusNode();

  @override
  void didUpdateWidget(OtherDetailField old) {
    super.didUpdateWidget(old);
    final incoming = widget.value ?? '';
    if (incoming != _controller.text && !_focus.hasFocus) {
      _controller.text = incoming;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.sm + Spacing.xs),
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        onChanged: widget.onChanged,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          prefixIcon: const Icon(Icons.subdirectory_arrow_right_rounded, size: 18),
        ),
      ),
    );
  }
}

/// A plain text field that reports every keystroke. Debouncing belongs to the controller, which
/// is the only thing that knows what a write costs.
final class IntakeTextField extends StatefulWidget {
  const IntakeTextField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.hint,
    this.helper,
    this.maxLines = 1,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.sentences,
    this.prefixIcon,
    this.mono = false,
    this.inputFormatters,
    this.enabled = true,
  });

  final String? value;
  final ValueChanged<String> onChanged;
  final String? label;
  final String? hint;
  final String? helper;
  final int maxLines;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final IconData? prefixIcon;

  /// Certificate numbers, hallmark strings and receipt codes are identifiers, so they render
  /// monospaced — the same rule the whole app follows for data.
  final bool mono;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;

  @override
  State<IntakeTextField> createState() => _IntakeTextFieldState();
}

class _IntakeTextFieldState extends State<IntakeTextField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value ?? '');
  final _focus = FocusNode();

  @override
  void didUpdateWidget(IntakeTextField old) {
    super.didUpdateWidget(old);
    // Never fight the operator mid-word: only adopt an external value while the field is idle.
    final incoming = widget.value ?? '';
    if (!_focus.hasFocus && incoming != _controller.text) {
      _controller.text = incoming;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      enabled: widget.enabled,
      onChanged: widget.onChanged,
      maxLines: widget.maxLines,
      keyboardType: widget.keyboardType,
      textCapitalization: widget.textCapitalization,
      inputFormatters: widget.inputFormatters,
      style: widget.mono ? AppTheme.mono(size: 14, color: context.scheme.onSurface) : null,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        helperText: widget.helper,
        helperMaxLines: 3,
        prefixIcon: widget.prefixIcon == null ? null : Icon(widget.prefixIcon, size: 18),
      ),
    );
  }
}

/// A labelled switch with a sentence under it. Used for every yes/no in the wizard, because a
/// bare switch with a two-word label is how "Strict tolerance" ended up meaning nothing.
final class ToggleRow extends StatelessWidget {
  const ToggleRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.blurb,
    this.icon,
    this.enabled = true,
  });

  final String title;
  final String? blurb;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData? icon;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return MergeSemantics(
      child: InkWell(
        borderRadius: Radii.rMd,
        onTap: enabled ? () => onChanged(!value) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: Spacing.sm + Spacing.xs),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: context.text.bodyLarge?.copyWith(
                        color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (blurb != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        blurb!,
                        style: context.text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Switch(value: value, onChanged: enabled ? onChanged : null),
            ],
          ),
        ),
      ),
    );
  }
}

/// A short explanatory strip inside a card — a consequence the operator should know before they
/// choose, not after. Gold, because nothing is wrong; something simply follows.
final class NoteStrip extends StatelessWidget {
  const NoteStrip({
    super.key,
    required this.text,
    this.icon = Icons.info_outline_rounded,
    this.tone = NoteTone.info,
  });

  final String text;
  final IconData icon;
  final NoteTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final (background, foreground) = switch (tone) {
      NoteTone.info => (dh.surfaceContainerLow, scheme.onSurfaceVariant),
      NoteTone.consequence => (dh.gold.withValues(alpha: 0.14), dh.goldText),
      NoteTone.risk => (scheme.errorContainer, scheme.onErrorContainer),
      NoteTone.good => (dh.successContainer, dh.success),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm + Spacing.xs,
        vertical: Spacing.sm + Spacing.xs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: Radii.rMd,
        border: Border.all(
          color: tone == NoteTone.info ? dh.outlineVariant : foreground.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: foreground),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              text,
              style: context.text.bodySmall?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

enum NoteTone { info, consequence, risk, good }

/// Vertical rhythm inside a step. One constant so the ten screens breathe identically.
final class Gap extends StatelessWidget {
  const Gap.sm({super.key}) : _height = Spacing.sm;
  const Gap.md({super.key}) : _height = Spacing.md;
  const Gap.lg({super.key}) : _height = Spacing.lg;

  final double _height;

  @override
  Widget build(BuildContext context) => SizedBox(height: _height);
}

/// Confirms anything irreversible or destructive — deleting a capture, dropping a stone,
/// abandoning a draft, minting a job number.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Keep it',
  bool destructive = true,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final answer = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// One place to put a failure sentence in front of the operator. Repositories and Postgres
/// already write in plain words; this does not paraphrase them.
void showFailure(BuildContext context, String message) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: scheme.errorContainer,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        showCloseIcon: true,
      ),
    );
}

/// Fire a controller call and put any refusal in front of the operator.
///
/// Every mutating method on `IntakeController` answers `null` on success and a sentence on
/// failure. A screen that ignores that answer is a screen where a rejected write looks like a
/// successful one — which is precisely how the mockups' shipping gate behaved. Call sites that
/// have nothing else to do with the result use this.
Future<void> runIntake(BuildContext context, Future<String?> Function() action) async {
  final failure = await action();
  if (failure != null && context.mounted) showFailure(context, failure);
}

void showDone(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
}
