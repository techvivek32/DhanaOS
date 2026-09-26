/// The pieces the five dispatch-and-billing surfaces share: the advice strip, the sticky action
/// bar, a money row, the shipment chips, the partner picker and the security protocol.
///
/// They live in one file — and the billing screens import it — because dispatch and invoicing are
/// one flow, not two: an Indian manufacturer cannot legally ship without a tax invoice (D-004), so
/// the shipment list shows the invoice and the invoice shows the dispatch. The corpus already
/// demonstrated the alternative: the same state wore three different colours across 46 files, and
/// "In Production" was a literal class list on one screen and a different literal on the next.
///
/// The load-bearing widget here is [SecurityProtocolCard]. `shipping_dispatch` drew this protocol
/// and its JavaScript toggled opacity classes without ever setting `.disabled`, so the piece could
/// be dispatched with the tamper-seal protocol incomplete. Here every tick is a
/// `shipment_checks` row, the count is read off those rows, and `fn_dispatch_shipment` refuses
/// while any of them is outstanding.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/customer_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

// ================================================================= advice

/// What a strip of prose is doing on the screen.
enum AdviceTone {
  /// Context the operator did not ask for but needs.
  info,

  /// What pressing the button will do. Gold, the house milestone colour.
  consequence,

  /// Something that will bite later — an unissued invoice, a missing customs reference.
  risk,

  /// A rule that has been satisfied.
  good,
}

/// A bordered line of prose, so no screen in this flow invents its own warning treatment.
final class AdviceNote extends StatelessWidget {
  const AdviceNote({
    super.key,
    required this.text,
    this.tone = AdviceTone.info,
    this.icon,
    this.action,
  });

  final String text;
  final AdviceTone tone;
  final IconData? icon;

  /// A single affordance on the right — "Raise it", "Add the reference".
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    final (Color background, Color foreground, IconData glyph) = switch (tone) {
      AdviceTone.info => (
          dh.surfaceContainerLow,
          scheme.onSurfaceVariant,
          Icons.info_outline_rounded,
        ),
      AdviceTone.consequence => (
          dh.gold.withValues(alpha: 0.14),
          dh.goldText,
          Icons.bolt_outlined,
        ),
      AdviceTone.risk => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          Icons.warning_amber_rounded,
        ),
      AdviceTone.good => (
          dh.successContainer,
          dh.success,
          Icons.check_circle_outline_rounded,
        ),
    };

    return Container(
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      decoration: BoxDecoration(
        color: background,
        borderRadius: Radii.rMd,
        border: Border.all(color: dh.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? glyph, size: 16, color: foreground),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              text,
              style: context.text.bodySmall?.copyWith(color: foreground),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: Spacing.sm),
            action!,
          ],
        ],
      ),
    );
  }
}

// ================================================================= footer

/// The sticky action bar the dispatch and billing surfaces share.
///
/// [blockedReason] renders as a visible strip, never as a tooltip: a long-press hint is
/// undiscoverable on a shop-floor tablet, which is how the mockups ended up with dead controls
/// nobody could explain. Unlike the CAD footer, the actions here are genuinely disabled when the
/// gate is shut — a dispatch that cannot succeed must not be pressable, because the mockup's
/// version *was* pressable and fired with the seal protocol unfinished.
final class StickyActions extends StatelessWidget {
  const StickyActions({
    super.key,
    required this.children,
    this.blockedReason,
    this.note,
    this.progress,
  });

  final List<Widget> children;

  /// Why the primary action is held shut, in the order the operator should fix it.
  final String? blockedReason;

  /// Small print under the buttons.
  final String? note;

  /// Set while a file is in flight — 'Uploading the signature'.
  final String? progress;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: dh.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (progress != null) ...[
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        progress!,
                        style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.sm + Spacing.xs),
              ],
              if (blockedReason != null) ...[
                AdviceNote(text: blockedReason!, tone: AdviceTone.risk),
                const SizedBox(height: Spacing.sm + Spacing.xs),
              ],
              ...children,
              if (note != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  note!,
                  textAlign: TextAlign.center,
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ================================================================= money

/// How loudly a money line reads. The label column never moves, so a stack of these stays
/// optically aligned — the reason convention 5 puts every figure in the monospace face.
enum AmountWeight {
  /// One charge, one tax line.
  line,

  /// A running total inside a block.
  subtotal,

  /// The figure the customer pays. One per document.
  total,
}

/// `Taxable value            ₹4,85,000.00` — a label, an optional detail, and a [Money].
///
/// D-004: money never reaches this widget as a double. It takes the [Money] and formats it,
/// Indian digit grouping included, because an operator in Surat reads a western-grouped figure
/// wrong.
final class AmountRow extends StatelessWidget {
  const AmountRow({
    super.key,
    required this.label,
    required this.amount,
    this.detail,
    this.weight = AmountWeight.line,
    this.valueColor,
  });

  final String label;
  final Money amount;

  /// The rate or basis behind the figure — 'CGST 1.5%', 'HSN 7113 · 3%'.
  final String? detail;

  final AmountWeight weight;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final isTotal = weight == AmountWeight.total;

    final labelStyle = switch (weight) {
      AmountWeight.line => context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      AmountWeight.subtotal => context.text.bodyMedium?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      AmountWeight.total => context.text.titleMedium?.copyWith(color: scheme.onSurface),
    };

    final valueStyle = AppTheme.mono(
      size: switch (weight) {
        AmountWeight.line => 13.5,
        AmountWeight.subtotal => 14.5,
        AmountWeight.total => 18,
      },
      weight: weight == AmountWeight.line ? FontWeight.w500 : FontWeight.w700,
      color: valueColor ?? scheme.onSurface,
    );

    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: isTotal ? Spacing.sm : Spacing.xs + 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: labelStyle),
                if (detail != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    detail!,
                    style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: Spacing.md),
          Text(amount.format(), style: valueStyle),
        ],
      ),
    );

    if (!isTotal) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 1, thickness: 1, color: context.dh.outlineVariant),
        row,
      ],
    );
  }
}

// ================================================================= shipment chips

/// One vocabulary for "where is this leg", used by the list, the leg screen and the delivery
/// record.
final class ShipmentStatusChip extends StatelessWidget {
  const ShipmentStatusChip(this.status, {super.key, this.dense = false});

  final ShipmentStatus status;
  final bool dense;

  @override
  Widget build(BuildContext context) => StatusChip(
        label: status.label,
        dense: dense,
        dot: status.isInFlight,
        tone: switch (status) {
          ShipmentStatus.draft => ChipTone.neutral,
          ShipmentStatus.dispatched || ShipmentStatus.inTransit => ChipTone.accent,
          ShipmentStatus.delivered => ChipTone.success,
          ShipmentStatus.exception => ChipTone.danger,
        },
        icon: switch (status) {
          ShipmentStatus.delivered => Icons.check_circle_outline_rounded,
          ShipmentStatus.exception => Icons.error_outline_rounded,
          _ => null,
        },
      );
}

/// A glyph per leg, so a list of six legs is scannable without reading the labels. The mockups
/// proved a job needs all of these — inbound wax from "Central Hub", to-lab
/// ("FEDEX: 9876543210"), from-lab, then final dispatch — and modelled exactly one.
IconData shipmentLegIcon(ShipmentLeg leg) => switch (leg) {
      ShipmentLeg.waxInbound => Icons.move_to_inbox_outlined,
      ShipmentLeg.toCaster => Icons.local_fire_department_outlined,
      ShipmentLeg.fromCaster => Icons.inbox_outlined,
      ShipmentLeg.toLab => Icons.workspace_premium_outlined,
      ShipmentLeg.fromLab => Icons.assignment_returned_outlined,
      ShipmentLeg.finalDispatch => Icons.local_shipping_outlined,
    };

/// One sentence about why the leg exists, for the tile that opens it.
String shipmentLegBlurb(ShipmentLeg leg) => switch (leg) {
      ShipmentLeg.waxInbound => 'A wax or master arriving from a hub or a bureau.',
      ShipmentLeg.toCaster => 'The tree going out to the casting house.',
      ShipmentLeg.fromCaster => 'The cast piece coming back to the bench.',
      ShipmentLeg.toLab => 'The finished piece going out for certification.',
      ShipmentLeg.fromLab => 'The piece and its report coming back from the lab.',
      ShipmentLeg.finalDispatch => 'The insured leg out to the jeweller or the customer.',
    };

// ================================================================= security protocol

/// The tamper-seal protocol, as rows rather than as opacity.
///
/// Every tick writes `shipment_checks.passed` and stamps who ticked it. `fn_dispatch_shipment`
/// counts the unticked rows and refuses, which is the difference between this and the source:
/// there the checkboxes were decoration and dispatch fired regardless.
///
/// A ticked seal step with no serial recorded cannot be verified later
/// ([ShipmentCheck.needsReference]), so the reference sits on the row and is asked for as soon as
/// the step is ticked — as a gold hint, not a block, because the operator may be holding the box
/// and reading the serial off it.
final class SecurityProtocolCard extends StatefulWidget {
  const SecurityProtocolCard({
    super.key,
    required this.shipment,
    required this.onToggle,
    required this.onReference,
    this.onAddStep,
    this.enabled = true,
  });

  final Shipment shipment;

  /// Tick or untick one step. Unticking deliberately does not clear the serial: a seal already
  /// applied to a box keeps its number.
  final void Function(ShipmentCheck check, {required bool passed}) onToggle;

  /// Called when the serial field loses focus or is submitted, never per keystroke.
  final void Function(ShipmentCheck check, String reference) onReference;

  /// Add a step the standard protocol does not cover — a customs seal, a second count for a
  /// melee-heavy piece.
  final VoidCallback? onAddStep;

  /// False once the leg is dispatched. The protocol then reads as the record of what was done.
  final bool enabled;

  @override
  State<SecurityProtocolCard> createState() => _SecurityProtocolCardState();
}

class _SecurityProtocolCardState extends State<SecurityProtocolCard> {
  /// One controller per check row, kept across rebuilds so typing a serial survives the parent
  /// re-reading the leg after a tick.
  final Map<String, TextEditingController> _refs = <String, TextEditingController>{};
  final Map<String, FocusNode> _focus = <String, FocusNode>{};

  @override
  void didUpdateWidget(SecurityProtocolCard old) {
    super.didUpdateWidget(old);
    _prune();
  }

  /// Drop controllers for checks that no longer exist, and refresh the text of any row the
  /// operator is not currently editing.
  void _prune() {
    final live = <String>{for (final c in widget.shipment.checks) c.id};
    for (final id in _refs.keys.toList()) {
      if (live.contains(id)) continue;
      _refs.remove(id)?.dispose();
      _focus.remove(id)?.dispose();
    }
    for (final check in widget.shipment.checks) {
      final controller = _refs[check.id];
      if (controller == null) continue;
      final hasFocus = _focus[check.id]?.hasFocus ?? false;
      final stored = check.reference ?? '';
      if (!hasFocus && controller.text != stored) controller.text = stored;
    }
  }

  @override
  void dispose() {
    for (final controller in _refs.values) {
      controller.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(ShipmentCheck check) =>
      _refs.putIfAbsent(check.id, () => TextEditingController(text: check.reference ?? ''));

  FocusNode _focusFor(ShipmentCheck check) => _focus.putIfAbsent(check.id, () {
        final node = FocusNode();
        node.addListener(() {
          if (node.hasFocus) return;
          final text = _refs[check.id]?.text ?? '';
          if (text.trim() == (check.reference ?? '').trim()) return;
          widget.onReference(check, text);
        });
        return node;
      });

  @override
  Widget build(BuildContext context) {
    final shipment = widget.shipment;
    final checks = shipment.orderedChecks;
    final complete = shipment.isSecurityComplete;

    return DhSectionCard(
      title: 'Security protocol',
      subtitle: widget.enabled
          ? 'Every step has to be ticked before this leg can be dispatched.'
          : 'What was done before this leg left the building.',
      leading: const Icon(Icons.shield_outlined),
      action: StatusChip(
        label: shipment.checkProgressLabel,
        mono: true,
        dense: true,
        tone: complete ? ChipTone.success : ChipTone.warning,
      ),
      child: checks.isEmpty
          ? EmptyState(
              compact: true,
              icon: Icons.shield_outlined,
              title: 'No protocol on this leg',
              message: 'A leg with no protocol would dispatch unguarded. Add the steps the '
                  'packing bench actually performs.',
              actionLabel: widget.onAddStep == null ? null : 'Add a step',
              onAction: widget.onAddStep,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < checks.length; i++) ...[
                  if (i > 0) const SizedBox(height: Spacing.sm),
                  _CheckRow(
                    check: checks[i],
                    position: i + 1,
                    enabled: widget.enabled,
                    controller: _controllerFor(checks[i]),
                    focusNode: _focusFor(checks[i]),
                    onToggle: (passed) => widget.onToggle(checks[i], passed: passed),
                    onSubmitted: (text) => widget.onReference(checks[i], text),
                  ),
                ],
                if (widget.onAddStep != null) ...[
                  const SizedBox(height: Spacing.sm + Spacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: widget.onAddStep,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Add a step'),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

final class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.check,
    required this.position,
    required this.enabled,
    required this.controller,
    required this.focusNode,
    required this.onToggle,
    required this.onSubmitted,
  });

  final ShipmentCheck check;
  final int position;
  final bool enabled;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<bool> onToggle;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return DhCard(
      tone: DhCardTone.inset,
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      accent: check.passed ? dh.success : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: check.passed,
                semanticLabel: check.label,
                visualDensity: VisualDensity.compact,
                onChanged: enabled ? (value) => onToggle(value ?? false) : null,
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: Text(
                    check.label,
                    style: context.text.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: check.passed ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 9, left: Spacing.sm),
                child: Text(
                  position.toString().padLeft(2, '0'),
                  style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          if (enabled)
            Padding(
              padding: const EdgeInsets.only(left: Spacing.xl + Spacing.xs, top: Spacing.xs),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.done,
                onSubmitted: onSubmitted,
                style: AppTheme.mono(size: 13, color: scheme.onSurface),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Seal or reference — e.g. TE-921',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: Spacing.sm + Spacing.xs,
                    vertical: Spacing.sm + 2,
                  ),
                ),
              ),
            )
          else if (check.hasReference)
            Padding(
              padding: const EdgeInsets.only(left: Spacing.xl + Spacing.xs, top: 2),
              child: Text(
                check.reference!,
                style: AppTheme.mono(size: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          if (check.needsReference)
            Padding(
              padding: const EdgeInsets.only(left: Spacing.xl + Spacing.xs, top: Spacing.xs),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 13, color: dh.goldText),
                  const SizedBox(width: Spacing.xs),
                  Expanded(
                    child: Text(
                      'Record the serial. A ticked seal with no number cannot be verified later.',
                      style: context.text.bodySmall?.copyWith(color: dh.goldText),
                    ),
                  ),
                ],
              ),
            ),
          if (check.passed && check.checkedAt != null)
            Padding(
              padding: const EdgeInsets.only(left: Spacing.xl + Spacing.xs, top: Spacing.xs),
              child: Text(
                'Ticked ${localTimestamp(check.checkedAt!)}',
                style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

// ================================================================= pickers

/// What came back from [pickPartner].
///
/// Three outcomes, not two: a plain nullable `Partner` cannot tell "backed out" from "detach the
/// one that is attached", and those write different things to the row.
sealed class PartnerChoice {
  const PartnerChoice();
}

final class PartnerPicked extends PartnerChoice {
  const PartnerPicked(this.partner);

  final Partner partner;
}

/// Detach the counterparty currently on the leg.
final class PartnerCleared extends PartnerChoice {
  const PartnerCleared();
}

/// Choose the partner on the other end of a leg.
///
/// Scoped by [kind] so a courier cannot be picked as the casting house — one of the impossible
/// combinations the mockups' flat pickers allowed. Null means the operator backed out.
Future<PartnerChoice?> pickPartner(
  BuildContext context, {
  required PartnerKind kind,
  String? selectedId,
  String? title,
}) =>
    showModalBottomSheet<PartnerChoice>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PartnerSheet(
        kind: kind,
        selectedId: selectedId,
        title: title ?? 'Choose a ${kind.label.toLowerCase()} partner',
      ),
    );

final class _PartnerSheet extends ConsumerWidget {
  const _PartnerSheet({required this.kind, required this.selectedId, required this.title});

  final PartnerKind kind;
  final String? selectedId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(partnerDirectoryProvider(kind));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: context.text.headlineSmall),
            const SizedBox(height: Spacing.md),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: async.when(
                loading: () => const LoadingSkeleton.list(count: 3),
                error: (error, _) => ErrorState(
                  compact: true,
                  title: 'The partner list did not load',
                  message: error is DhFailure
                      ? error.message
                      : 'DhanaOS could not read the partner directory. Check the connection '
                          'and try again.',
                  onRetry: () => ref.invalidate(partnerDirectoryProvider(kind)),
                ),
                data: (partners) {
                  final active = [for (final p in partners) if (p.isActive) p];
                  if (active.isEmpty) {
                    return EmptyState(
                      compact: true,
                      icon: Icons.handshake_outlined,
                      title: 'No ${kind.label.toLowerCase()} partner on file',
                      message: 'Add the partner under Settings first, then come back and '
                          'attach it to this leg.',
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: active.length,
                    separatorBuilder: (_, __) => const SizedBox(height: Spacing.sm),
                    itemBuilder: (_, index) {
                      final partner = active[index];
                      return SelectableTile(
                        title: partner.name,
                        blurb: [
                          partner.kind.label,
                          if (partner.contactName?.trim().isNotEmpty ?? false)
                            partner.contactName!.trim(),
                          if (partner.phone?.trim().isNotEmpty ?? false) partner.phone!.trim(),
                        ].join(' · '),
                        icon: Icons.storefront_outlined,
                        inGroup: true,
                        selected: partner.id == selectedId,
                        onTap: () =>
                            Navigator.of(context).pop(PartnerPicked(partner)),
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: Spacing.sm),
            if (selectedId != null)
              TextButton(
                onPressed: () => Navigator.of(context).pop(const PartnerCleared()),
                child: const Text('Detach the current partner'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================= small fields

/// A labelled text field in the `DataPair` idiom — uppercase mono micro-label above the input —
/// so a column of them reads as a form rather than as floating Material labels.
final class LabelledField extends StatelessWidget {
  const LabelledField({
    super.key,
    required this.label,
    required this.controller,
    this.focusNode,
    this.hint,
    this.helperText,
    this.errorText,
    this.enabled = true,
    this.mono = false,
    this.uppercase = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.maxLength,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.trailing,
  });

  final String label;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hint;
  final String? helperText;
  final String? errorText;
  final bool enabled;

  /// True for anything that is an identifier — a waybill, a customs reference, a UTR.
  final bool mono;

  /// Forces the input to uppercase as it is typed. A waybill is quoted over the phone, and the
  /// mockup was right to shout it.
  final bool uppercase;

  final int minLines;
  final int maxLines;
  final int? maxLength;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  /// Sits on the label row — a hint chip, a paste affordance.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label.toUpperCase(),
                style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
        const SizedBox(height: Spacing.sm),
        TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          minLines: minLines,
          maxLines: maxLines,
          maxLength: maxLength,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
          textCapitalization:
              uppercase ? TextCapitalization.characters : TextCapitalization.sentences,
          inputFormatters: uppercase ? const [UpperCaseFormatter()] : null,
          style: mono
              ? AppTheme.mono(size: 15, weight: FontWeight.w600, color: scheme.onSurface)
              : null,
          decoration: InputDecoration(
            hintText: hint,
            helperText: helperText,
            helperMaxLines: 3,
            errorText: errorText,
            errorMaxLines: 3,
            alignLabelWithHint: maxLines > 1,
          ),
        ),
      ],
    );
  }
}

/// Uppercases as the operator types, leaving the caret where it was.
final class UpperCaseFormatter extends TextInputFormatter {
  const UpperCaseFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      TextEditingValue(
        text: newValue.text.toUpperCase(),
        selection: newValue.selection,
        composing: TextRange.empty,
      );
}

/// A switch row with a reason under it. Used for insurance, signature-on-delivery and the
/// international flag, each of which changes what the courier is told.
final class ToggleRow extends StatelessWidget {
  const ToggleRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.blurb,
    this.icon,
    this.enabled = true,
    this.lockedReason,
  });

  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? blurb;
  final IconData? icon;
  final bool enabled;

  /// Set when the value is forced by another choice — an international courier forces the
  /// customs flag on, and saying so beats a switch that springs back.
  final String? lockedReason;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final live = enabled && onChanged != null && lockedReason == null;

    return DhCard(
      tone: DhCardTone.inset,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm + Spacing.xs,
        vertical: Spacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
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
                if (blurb != null || lockedReason != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    lockedReason ?? blurb!,
                    style: context.text.bodySmall?.copyWith(
                      color: lockedReason == null
                          ? scheme.onSurfaceVariant
                          : context.dh.goldText,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Switch(
            value: value,
            onChanged: live ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

// ================================================================= address

/// The shape `shipments.to_address` and `customers.address` are read and written in.
///
/// The column is `jsonb` with no schema, and the mockups had no address field at all — the
/// dispatch screen offered "Return to Jeweler / Direct to Customer" and then had nowhere to put
/// where either of those actually was. This is that shape, and it is deliberately snapshotted
/// onto the leg rather than joined from the customer: the address a package was sent to must not
/// change three months later because the retailer moved.
///
/// Reading tolerates the key spellings a hand-entered customer record turns up with; writing uses
/// one spelling only.
@immutable
final class ShipAddress {
  const ShipAddress({
    this.name,
    this.line1,
    this.line2,
    this.city,
    this.state,
    this.postcode,
    this.country,
    this.phone,
  });

  factory ShipAddress.fromMap(Map<String, dynamic> map) {
    String? read(List<String> keys) {
      for (final key in keys) {
        final value = map[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }

    return ShipAddress(
      name: read(const ['name', 'contact_name', 'attention']),
      line1: read(const ['line1', 'address1', 'street', 'address']),
      line2: read(const ['line2', 'address2', 'area', 'landmark']),
      city: read(const ['city', 'town']),
      state: read(const ['state', 'region', 'province']),
      postcode: read(const ['postcode', 'pincode', 'pin', 'zip', 'postal_code']),
      country: read(const ['country']),
      phone: read(const ['phone', 'mobile', 'contact']),
    );
  }

  /// Prefill for a "Return to Jeweller" leg: the retailer we manufacture for is the customer
  /// row, so their address is already on file and should not be retyped.
  factory ShipAddress.fromCustomer(Customer customer) {
    final base = ShipAddress.fromMap(customer.address);
    return base.copyWith(
      name: base.name ?? customer.contactName?.trim() ?? customer.name,
      phone: base.phone ?? customer.phone?.trim(),
    );
  }

  final String? name;
  final String? line1;
  final String? line2;
  final String? city;
  final String? state;
  final String? postcode;
  final String? country;
  final String? phone;

  static const empty = ShipAddress();

  ShipAddress copyWith({
    String? name,
    String? line1,
    String? line2,
    String? city,
    String? state,
    String? postcode,
    String? country,
    String? phone,
  }) =>
      ShipAddress(
        name: name ?? this.name,
        line1: line1 ?? this.line1,
        line2: line2 ?? this.line2,
        city: city ?? this.city,
        state: state ?? this.state,
        postcode: postcode ?? this.postcode,
        country: country ?? this.country,
        phone: phone ?? this.phone,
      );

  /// Only the fields that carry something. An empty string in a jsonb column reads as an address
  /// line on every screen that prints it.
  Map<String, dynamic> toMap() {
    final out = <String, dynamic>{};
    void put(String key, String? value) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) out[key] = trimmed;
    }

    put('name', name);
    put('line1', line1);
    put('line2', line2);
    put('city', city);
    put('state', state);
    put('postcode', postcode);
    put('country', country);
    put('phone', phone);
    return out;
  }

  bool get isEmpty => toMap().isEmpty;

  /// What a courier will not accept the package without.
  List<String> get missing => <String>[
        if (name?.trim().isEmpty ?? true) 'Recipient name',
        if (line1?.trim().isEmpty ?? true) 'Street address',
        if (city?.trim().isEmpty ?? true) 'City',
        if (postcode?.trim().isEmpty ?? true) 'PIN / postcode',
      ];

  bool get isDeliverable => missing.isEmpty;

  /// The GSTIN-independent fallback for an invoice's place of supply.
  String? get placeOfSupply => state?.trim().isEmpty ?? true ? null : state!.trim();

  /// 'Kavita Rao, 14 Ratan Plaza, Opera House, Mumbai, Maharashtra 400004'.
  String get oneLine {
    final parts = <String>[
      if (name?.trim().isNotEmpty ?? false) name!.trim(),
      if (line1?.trim().isNotEmpty ?? false) line1!.trim(),
      if (line2?.trim().isNotEmpty ?? false) line2!.trim(),
      if (city?.trim().isNotEmpty ?? false) city!.trim(),
      [
        if (state?.trim().isNotEmpty ?? false) state!.trim(),
        if (postcode?.trim().isNotEmpty ?? false) postcode!.trim(),
      ].join(' ').trim(),
      if (country?.trim().isNotEmpty ?? false) country!.trim(),
    ];
    return parts.where((p) => p.isNotEmpty).join(', ');
  }

  @override
  bool operator ==(Object other) =>
      other is ShipAddress &&
      other.name == name &&
      other.line1 == line1 &&
      other.line2 == line2 &&
      other.city == city &&
      other.state == state &&
      other.postcode == postcode &&
      other.country == country &&
      other.phone == phone;

  @override
  int get hashCode => Object.hash(name, line1, line2, city, state, postcode, country, phone);

  /// Multi-line, the way it goes on a label.
  List<String> get lines => <String>[
        if (name?.trim().isNotEmpty ?? false) name!.trim(),
        if (line1?.trim().isNotEmpty ?? false) line1!.trim(),
        if (line2?.trim().isNotEmpty ?? false) line2!.trim(),
        [
          if (city?.trim().isNotEmpty ?? false) city!.trim(),
          if (state?.trim().isNotEmpty ?? false) state!.trim(),
          if (postcode?.trim().isNotEmpty ?? false) postcode!.trim(),
        ].join(' ').trim(),
        if (country?.trim().isNotEmpty ?? false) country!.trim(),
        if (phone?.trim().isNotEmpty ?? false) phone!.trim(),
      ].where((line) => line.isNotEmpty).toList();
}

/// The address block on a final-dispatch leg.
///
/// Edits are reported when the group loses focus, not per keystroke: a courier address is seven
/// fields and one PATCH per character would be absurd.
final class AddressCard extends StatefulWidget {
  const AddressCard({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.title = 'Deliver to',
    this.subtitle,
    this.prefillLabel,
    this.onPrefill,
  });

  final ShipAddress value;
  final ValueChanged<ShipAddress> onChanged;
  final bool enabled;
  final String title;
  final String? subtitle;

  /// 'Use the customer on file' — offered when there is a record worth copying.
  final String? prefillLabel;
  final VoidCallback? onPrefill;

  @override
  State<AddressCard> createState() => _AddressCardState();
}

class _AddressCardState extends State<AddressCard> {
  late final Map<String, TextEditingController> _fields = {
    'name': TextEditingController(text: widget.value.name ?? ''),
    'line1': TextEditingController(text: widget.value.line1 ?? ''),
    'line2': TextEditingController(text: widget.value.line2 ?? ''),
    'city': TextEditingController(text: widget.value.city ?? ''),
    'state': TextEditingController(text: widget.value.state ?? ''),
    'postcode': TextEditingController(text: widget.value.postcode ?? ''),
    'country': TextEditingController(text: widget.value.country ?? ''),
    'phone': TextEditingController(text: widget.value.phone ?? ''),
  };

  /// True while any field in the group holds focus. External updates are not adopted then — the
  /// operator is mid-address and having it rewritten under the caret is worse than being one
  /// round trip stale.
  bool _editing = false;

  @override
  void didUpdateWidget(AddressCard old) {
    super.didUpdateWidget(old);
    if (_editing || widget.value == old.value) return;
    // A prefill or a server round trip changed the address under us; adopt it.
    _set('name', widget.value.name);
    _set('line1', widget.value.line1);
    _set('line2', widget.value.line2);
    _set('city', widget.value.city);
    _set('state', widget.value.state);
    _set('postcode', widget.value.postcode);
    _set('country', widget.value.country);
    _set('phone', widget.value.phone);
  }

  void _set(String key, String? value) {
    final controller = _fields[key]!;
    final text = value ?? '';
    if (controller.text != text) controller.text = text;
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _read(String key) {
    final text = _fields[key]!.text.trim();
    return text.isEmpty ? null : text;
  }

  void _flush() {
    final next = ShipAddress(
      name: _read('name'),
      line1: _read('line1'),
      line2: _read('line2'),
      city: _read('city'),
      state: _read('state'),
      postcode: _read('postcode'),
      country: _read('country'),
      phone: _read('phone'),
    );
    if (next == widget.value) return;
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      final lines = widget.value.lines;
      return DhSectionCard(
        title: widget.title,
        subtitle: widget.subtitle,
        leading: const Icon(Icons.place_outlined),
        child: lines.isEmpty
            ? Text(
                'No address was recorded on this leg.',
                style: context.text.bodyMedium?.copyWith(
                  color: context.scheme.onSurfaceVariant,
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in lines)
                    Text(
                      line,
                      style: AppTheme.mono(size: 13, color: context.scheme.onSurface),
                    ),
                ],
              ),
      );
    }

    return DhSectionCard(
      title: widget.title,
      subtitle: widget.subtitle,
      leading: const Icon(Icons.place_outlined),
      action: widget.onPrefill == null
          ? null
          : TextButton(
              onPressed: widget.onPrefill,
              child: Text(widget.prefillLabel ?? 'Prefill'),
            ),
      child: Focus(
        onFocusChange: (hasFocus) {
          _editing = hasFocus;
          if (!hasFocus) _flush();
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabelledField(
              label: 'Recipient',
              controller: _fields['name']!,
              hint: 'Who signs for it',
            ),
            const SizedBox(height: Spacing.md),
            LabelledField(
              label: 'Street address',
              controller: _fields['line1']!,
              hint: 'Shop or flat, building, street',
            ),
            const SizedBox(height: Spacing.md),
            LabelledField(
              label: 'Area or landmark',
              controller: _fields['line2']!,
              hint: 'Optional',
            ),
            const SizedBox(height: Spacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: LabelledField(
                    label: 'City',
                    controller: _fields['city']!,
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: LabelledField(
                    label: 'State',
                    controller: _fields['state']!,
                    helperText: 'Decides the place of supply on the invoice.',
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: LabelledField(
                    label: 'PIN / postcode',
                    controller: _fields['postcode']!,
                    mono: true,
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: LabelledField(
                    label: 'Country',
                    controller: _fields['country']!,
                    hint: 'India',
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            LabelledField(
              label: 'Phone',
              controller: _fields['phone']!,
              mono: true,
              keyboardType: TextInputType.phone,
              helperText: 'The courier calls this number before attempting delivery.',
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================= formatting

/// Convention 7: Postgres hands us UTC, the operator reads local time.
String localTimestamp(DateTime utc, {bool withTime = true}) =>
    (withTime ? _stampWithTime : _stampDateOnly).format(utc.toLocal());

final _stampWithTime = DateFormat('d MMM yyyy · HH:mm');
final _stampDateOnly = DateFormat('d MMM yyyy');

/// '4h' / '3d' — how long something has been in transit, in the rail's own shorthand.
String shortSpan(Duration d) {
  if (d.inDays >= 1) return '${d.inDays}d';
  if (d.inHours >= 1) return '${d.inHours}h';
  return '${d.inMinutes}m';
}
