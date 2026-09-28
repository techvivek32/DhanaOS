/// Goods-in custody for a client's own stone.
///
/// This card exists because the mockups did not have one. `stone_requirements/customer_supplied`
/// rendered a "Verified & Logged in Inventory" status chip and captured **nothing**: no declared
/// value, no verifier, no timestamp, no receipt number, no risk acknowledgement. A workshop taking
/// a $12,500 diamond into its care with no record of any of that is carrying legal and insurance
/// exposure, not running a process.
///
/// So the record is complete or it is not made. `SpecRepository.recordCustody` refuses a partial
/// write field by field with its own sentence for each; this card refuses to *send* a partial one,
/// and names what is still missing under a disabled button rather than greying it silently.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/widgets/date_field.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class CustodyCard extends ConsumerStatefulWidget {
  const CustodyCard({
    super.key,
    required this.draft,
    required this.stone,
    required this.controller,
  });

  final IntakeDraft draft;
  final Stone stone;
  final IntakeController controller;

  @override
  ConsumerState<CustodyCard> createState() => _CustodyCardState();
}

class _CustodyCardState extends ConsumerState<CustodyCard> {
  late Money _declared;
  late String _receipt;
  late DateTime _verifiedAt;
  late bool _riskAck;
  bool _editing = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _seed();
    _editing = !widget.stone.hasCustodyRecord;
  }

  @override
  void didUpdateWidget(CustodyCard old) {
    super.didUpdateWidget(old);
    // A fresh stone id means a different stone in the same slot — start its record over.
    if (old.stone.id != widget.stone.id) {
      _seed();
      _editing = !widget.stone.hasCustodyRecord;
    }
  }

  void _seed() {
    final stone = widget.stone;
    final currency = widget.draft.currency;
    _declared = stone.declaredValue(currency) ?? Money(0, currency);
    _receipt = stone.receiptCode ?? '';
    _verifiedAt = stone.verifiedAt?.toLocal() ?? DateTime.now();
    _riskAck = stone.riskAck;
  }

  /// Every field the repository will insist on, in the order the counter staff fills them.
  /// Convention 8: each one says what is missing, not that "some fields are required".
  String? get _blockReason {
    if (_declared.isZero || _declared.isNegative) {
      return 'Enter the value the client declares for this stone. It is what the insurance '
          'cover is written against.';
    }
    if (_receipt.trim().isEmpty) {
      return 'Enter the receipt number you gave the client when you took the stone.';
    }
    if (!_riskAck) {
      return 'The client has to accept the risk terms before the stone changes hands. '
          'Tick the acknowledgement once they have.';
    }
    return null;
  }

  Future<void> _record() async {
    final blocked = _blockReason;
    if (blocked != null || _busy) return;
    setState(() => _busy = true);
    final failure = await widget.controller.recordCustody(
      stoneId: widget.stone.id,
      declaredValue: _declared,
      receiptCode: _receipt,
      riskAck: _riskAck,
      verifiedAt: _verifiedAt,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (failure == null) _editing = false;
    });
    if (failure != null) {
      showFailure(context, failure);
    } else {
      showDone(context, 'Custody recorded. The client now has a receipt on the job record.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final stone = widget.stone;
    final recorded = stone.hasCustodyRecord;

    return DhSectionCard(
      title: 'Goods-in custody',
      subtitle: recorded
          ? 'The workshop is holding this stone against the record below.'
          : 'The stone does not change hands until all four lines are filled in.',
      leading: const Icon(Icons.shield_outlined),
      accent: recorded ? context.dh.success : context.scheme.error,
      child: recorded && !_editing ? _recordView(context) : _form(context),
    );
  }

  // ---------------------------------------------------------------- recorded

  Widget _recordView(BuildContext context) {
    final stone = widget.stone;
    final currency = widget.draft.currency;
    final verifier = ref.watch(currentUserProvider).value;
    final verifiedByMe = verifier != null && verifier.id == stone.verifiedBy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DataPairGrid(
          children: [
            DataPair.money(
              label: 'Declared value',
              amount: stone.declaredValue(currency) ?? Money(0, currency),
              emphasis: DataEmphasis.display,
            ),
            DataPair.mono(
              label: 'Receipt given',
              value: stone.receiptCode ?? DataPair.placeholder,
              emphasis: DataEmphasis.strong,
            ),
            if (stone.verifiedAt != null)
              DataPair.timestamp(label: 'Verified', utc: stone.verifiedAt!),
            DataPair.mono(
              label: 'Verified by',
              // D-008: never a hardcoded identity. Falls back to the stored id rather than
              // inventing a name the session cannot vouch for.
              value: verifiedByMe
                  ? verifier.fullName
                  : (stone.verifiedBy ?? DataPair.placeholder),
            ),
          ],
        ),
        const Gap.md(),
        const NoteStrip(
          tone: NoteTone.good,
          icon: Icons.verified_user_outlined,
          text: 'Risk terms acknowledged by the client. The stone is insured at the declared '
              'value for as long as it is in the workshop.',
        ),
        const Gap.md(),
        OutlinedButton.icon(
          onPressed: () => setState(() => _editing = true),
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: const Text('Amend the custody record'),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- form

  Widget _form(BuildContext context) {
    final blocked = _blockReason;
    final verifier = ref.watch(currentUserProvider).value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NoteStrip(
          tone: NoteTone.risk,
          icon: Icons.warning_amber_rounded,
          text: 'You are taking a customer\'s stone into the workshop. Until it is handed back '
              'or set into the finished piece, it is our responsibility.',
        ),
        const Gap.md(),
        MoneyField(
          value: _declared,
          label: 'Declared value',
          helperText: 'What the client says it is worth. Insurance cover is written against '
              'this figure, so take it from the certificate or a valuation, not a guess.',
          onChanged: (value) => setState(() => _declared = value),
        ),
        const Gap.md(),
        IntakeTextField(
          value: _receipt,
          label: 'Receipt number given to the client',
          hint: 'RCPT-2026-0417',
          helper: 'The number on the paper the client walked out with. It is what they will '
              'quote when they ring.',
          mono: true,
          textCapitalization: TextCapitalization.characters,
          onChanged: (value) => setState(() => _receipt = value),
        ),
        const Gap.md(),
        FieldBlock(
          label: 'Received on',
          helper: 'Today unless the stone came in earlier and is only being logged now.',
          child: DateField(
            value: _verifiedAt,
            firstDate: DateTime.now().subtract(const Duration(days: 365)),
            lastDate: DateTime.now(),
            helpText: 'When did the stone arrive?',
            emptyLabel: 'Not recorded',
            onChanged: (value) => setState(() => _verifiedAt = value),
          ),
        ),
        const Gap.md(),
        ToggleRow(
          title: 'Client has acknowledged the risk terms',
          blurb: 'Setting, sizing and polishing a client-owned stone carries a risk of chipping '
              'or loss. Tick this only once the client has actually accepted it.',
          icon: Icons.gavel_outlined,
          value: _riskAck,
          onChanged: (value) => setState(() => _riskAck = value),
        ),
        if (verifier != null) ...[
          const Gap.sm(),
          Text(
            'Recorded against ${verifier.fullName}. Your name goes on the custody line.',
            style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
        ],
        const Gap.md(),
        if (blocked != null) ...[
          NoteStrip(tone: NoteTone.consequence, icon: Icons.lock_outline_rounded, text: blocked),
          const Gap.sm(),
        ],
        FilledButton.icon(
          // The gate is real: a null handler, never a painted-disabled button that still fires.
          onPressed: blocked == null && !_busy ? _record : null,
          icon: _busy
              ? SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.scheme.onPrimary,
                  ),
                )
              : const Icon(Icons.shield_outlined, size: 18),
          label: Text(
            widget.stone.hasCustodyRecord
                ? 'Save the amended record'
                : 'Take custody of this stone',
          ),
        ),
        if (widget.stone.hasCustodyRecord && _editing) ...[
          const Gap.sm(),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _seed();
                      _editing = false;
                    }),
            child: const Text('Cancel the amendment'),
          ),
        ],
      ],
    );
  }
}
