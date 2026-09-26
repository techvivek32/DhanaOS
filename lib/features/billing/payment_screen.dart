/// Money actually received against an invoice, and what is still outstanding.
///
/// The other half of the hole D-004 names. The 46 mockups had no invoice, and so necessarily no
/// receipt either: a job's "Value $4,850" was a literal on a card and nothing in the corpus could
/// say whether a rupee of it had ever arrived.
///
/// Three rules are rendered here rather than discovered on a refusal:
///
///  * **Only an issued invoice takes money.** `recordPayment` refuses otherwise. A receipt against
///    a draft has nothing legal to be a receipt for.
///  * **The currency has to match.** A USD receipt against an INR invoice is reconciled
///    separately, never summed — so the field is locked to the invoice's currency rather than
///    offering a selector that would produce a refusal.
///  * **A receipt with no reference cannot be matched to a bank statement.** The column allows
///    null and this screen still asks, then says so in the confirmation if it is left blank —
///    because "we think it came in" is not reconciliation.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/billing/amount_words.dart';
import 'package:dhanaos/features/billing/billing_actions.dart';
import 'package:dhanaos/features/billing/billing_gateway.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/shipping/shipping_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// How the money arrived. Stored lowercase in `payments.method`, which is free text — the list is
/// here so a shop does not end up with "NEFT", "neft " and "Neft" as three payment methods.
enum PaymentMethod {
  neft('neft', 'NEFT / RTGS', 'UTR number', Icons.account_balance_outlined),
  upi('upi', 'UPI', 'UPI transaction id', Icons.qr_code_2_rounded),
  cheque('cheque', 'Cheque', 'Cheque number', Icons.receipt_outlined),
  card('card', 'Card', 'Approval code', Icons.credit_card_rounded),
  cash('cash', 'Cash', 'Receipt book number', Icons.payments_outlined),
  adjustment('adjustment', 'Adjustment', 'What is being set off', Icons.compare_arrows_rounded);

  const PaymentMethod(this.wire, this.label, this.referenceLabel, this.icon);

  /// Written to `payments.method`.
  final String wire;
  final String label;

  /// What the reference field is called for this method. A UTR and a cheque number are not the
  /// same thing, and labelling both "reference" is how neither gets filled in.
  final String referenceLabel;

  final IconData icon;

  /// Cash across a counter has no bank trail, so an unreferenced cash receipt is normal rather
  /// than a reconciliation problem.
  bool get needsBankReference => this != cash && this != adjustment;
}

final class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({super.key, required this.jobId, required this.invoiceId});

  final String jobId;
  final String invoiceId;

  static Future<void> push(
    BuildContext context, {
    required String jobId,
    required String invoiceId,
  }) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PaymentScreen(jobId: jobId, invoiceId: invoiceId),
        ),
      );

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  final TextEditingController _reference = TextEditingController();

  Money? _amount;
  PaymentMethod _method = PaymentMethod.neft;
  DateTime _receivedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _reference.addListener(_onTyped);
  }

  void _onTyped() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _reference
      ..removeListener(_onTyped)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(billingBundleProvider(widget.jobId));

    return async.when(
      loading: () => const _Frame(
        child: Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoadingSkeleton(height: 96),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
            ],
          ),
        ),
      ),
      error: (error, _) => _Frame(
        child: ErrorState(
          title: 'The payment record did not open',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read the invoice. Check the connection and try again.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(billingBundleProvider(widget.jobId)),
        ),
      ),
      data: (bundle) {
        final invoice = bundle.invoiceById(widget.invoiceId);
        if (invoice == null) {
          return _Frame(
            child: ErrorState(
              icon: Icons.receipt_long_outlined,
              title: 'That invoice is no longer on this job',
              message: 'It was removed, or it belongs to a different job order.',
              onSecondary: () => Navigator.of(context).maybePop(),
              secondaryLabel: 'Go back',
            ),
          );
        }
        return _loaded(bundle, invoice);
      },
    );
  }

  // -------------------------------------------------------------- state

  Money _amountFor(Invoice invoice) =>
      _amount ?? Money(0, invoice.currency);

  String? get _typedReference {
    final text = _reference.text.trim();
    return text.isEmpty ? null : text;
  }

  String? _blockedReason(Invoice invoice, Permissions permissions) {
    if (!permissions.canApprovePrice) {
      return permissions.blockReason(Capability.approvePrice);
    }
    if (!invoice.isIssued) {
      return 'Invoice ${invoice.invoiceNo} is still a draft. Issue it before recording money '
          'against it.';
    }
    if (_amountFor(invoice).minor <= 0) {
      return 'Enter the amount that arrived. A refund is a credit note, not a negative payment.';
    }
    if (_receivedAt.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
      return 'A receipt cannot be dated in the future. Set the date the money actually cleared.';
    }
    return null;
  }

  bool _canRecord(Invoice invoice, Permissions permissions) =>
      _blockedReason(invoice, permissions) == null;

  // -------------------------------------------------------------- actions

  Future<void> _pickDate(Invoice invoice) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _receivedAt,
      firstDate: invoice.invoiceDate.subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: 'Date the money cleared',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _receivedAt =
          DateTime(picked.year, picked.month, picked.day, _receivedAt.hour, _receivedAt.minute);
    });
  }

  Future<void> _record(BillingBundle bundle, Invoice invoice) async {
    final amount = _amountFor(invoice);
    final reference = _typedReference;
    final overpay = amount.minor > invoice.amountDue.minor;

    final agreed = await confirmAction(
      context,
      title: 'Record ${amount.format()}?',
      message: [
        '${amount.format()} received by ${_method.label} against invoice '
            '${invoice.invoiceNo}.',
        amountInWords(amount),
        if (reference == null && _method.needsBankReference)
          'NO reference recorded. This receipt cannot be matched to a bank statement later.'
        else if (reference != null)
          '${_method.referenceLabel}: $reference.',
        if (overpay)
          'This is more than the ${invoice.amountDue.format()} outstanding. The excess will show '
              'as an overpayment on this invoice — if it belongs to another one, record it there '
              'instead.',
        'A receipt is part of the audit trail and cannot be deleted from this screen.',
      ].join('\n\n'),
      confirmLabel: 'Record the payment',
      cancelLabel: 'Not yet',
    );
    if (!agreed || !mounted) return;

    try {
      await ref.read(billingActionsProvider.notifier).recordPayment(
            jobId: bundle.job.id,
            invoice: invoice,
            amount: amount,
            method: _method.wire,
            reference: reference,
            receivedAt: _receivedAt,
          );
      if (!mounted) return;
      showDone(context, '${amount.format()} recorded against ${invoice.invoiceNo}.');
      setState(() {
        _amount = null;
        _reference.clear();
        _receivedAt = DateTime.now();
      });
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  // -------------------------------------------------------------- build

  Widget _loaded(BillingBundle bundle, Invoice invoice) {
    final task = ref.watch(billingActionsProvider);
    final busy = task != null;
    final permissions = ref.watch(permissionsProvider);
    final payments = invoice.payments.toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payments'),
        actions: [
          IconButton(
            onPressed: busy ? null : () => ref.invalidate(billingBundleProvider(bundle.job.id)),
            tooltip: 'Re-read this invoice',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(billingBundleProvider(bundle.job.id).future),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xl),
          children: [
            _balance(bundle, invoice),
            if (!invoice.isIssued) ...[
              const SizedBox(height: Spacing.md),
              AdviceNote(
                tone: AdviceTone.risk,
                text: 'Invoice ${invoice.invoiceNo} is still a draft. Issue it before recording '
                    'money against it — a receipt against a draft has nothing legal to be a '
                    'receipt for.',
              ),
            ],
            const SizedBox(height: Spacing.lg),
            SectionHeading(title: 'Received', count: payments.length),
            const SizedBox(height: Spacing.sm + Spacing.xs),
            if (payments.isEmpty)
              const EmptyState(
                compact: true,
                icon: Icons.account_balance_wallet_outlined,
                title: 'Nothing received yet',
                message: 'Record the first receipt below. Every payment keeps its own reference, '
                    'so the invoice can be reconciled against a bank statement line by line.',
              )
            else
              for (final payment in payments) ...[
                _PaymentRow(payment: payment, recordedBy: bundle.nameFor(payment.recordedBy)),
                const SizedBox(height: Spacing.sm),
              ],
            if (invoice.isIssued && permissions.canApprovePrice) ...[
              const SizedBox(height: Spacing.lg),
              _recordCard(invoice, enabled: !busy),
            ],
          ],
        ),
      ),
      bottomNavigationBar: StickyActions(
        blockedReason: _blockedReason(invoice, permissions),
        note: invoice.isPaid
            ? 'This invoice is settled in full.'
            : 'Only money that has actually cleared belongs here.',
        children: [
          FilledButton.icon(
            onPressed: _canRecord(invoice, permissions) && !busy
                ? () => unawaited(_record(bundle, invoice))
                : null,
            icon: task == BillingTask.recordPayment
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_card_rounded, size: 18),
            label: const Text('Record the payment'),
          ),
        ],
      ),
    );
  }

  Widget _balance(BillingBundle bundle, Invoice invoice) {
    final due = invoice.amountDue;

    return DhCard(
      accent: invoice.isPaid ? context.dh.success : context.dh.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusChip.code(invoice.invoiceNo),
              const SizedBox(width: Spacing.sm),
              StatusChip(
                label: invoice.isIssued ? 'Issued' : 'Draft',
                dense: true,
                tone: invoice.isIssued ? ChipTone.success : ChipTone.neutral,
              ),
              const Spacer(),
              StatusChip(
                label: invoice.isPaid
                    ? 'Paid'
                    : invoice.isPartlyPaid
                        ? 'Part paid'
                        : 'Unpaid',
                dense: true,
                tone: invoice.isPaid
                    ? ChipTone.success
                    : invoice.isPartlyPaid
                        ? ChipTone.warning
                        : ChipTone.neutral,
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            bundle.customer?.name ?? bundle.job.displayTitle,
            style: context.text.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: Spacing.md),
          AmountRow(label: 'Invoiced', amount: invoice.grandTotal),
          AmountRow(label: 'Received', amount: invoice.amountPaid),
          AmountRow(
            label: 'Outstanding',
            amount: due,
            weight: AmountWeight.total,
            valueColor: due.isZero ? context.dh.success : null,
          ),
          if (!due.isZero) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              amountInWords(due),
              style: context.text.bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _recordCard(Invoice invoice, {required bool enabled}) {
    final due = invoice.amountDue;
    final amount = _amountFor(invoice);
    final missingReference = _typedReference == null && _method.needsBankReference;

    return DhSectionCard(
      title: 'Record a receipt',
      subtitle: 'What cleared, how it came in, and the number it can be matched against.',
      leading: const Icon(Icons.add_card_rounded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MoneyField(
            value: amount,
            enabled: enabled,
            label: 'Amount received',
            helperText: due.isZero
                ? 'This invoice is already settled. Anything recorded here is an overpayment.'
                : '${due.format()} outstanding.',
            // No `onCurrencyChanged`, so the prefix stays a plain symbol: the field is locked to
            // the invoice's currency because `recordPayment` refuses a mismatch, and a selector
            // that can only produce a refusal is worse than no selector at all.
            onChanged: (money) => setState(() => _amount = money),
          ),
          if (!due.isZero && enabled) ...[
            const SizedBox(height: Spacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _amount = due),
                icon: const Icon(Icons.done_all_rounded, size: 18),
                label: Text('Settle in full · ${due.format()}'),
              ),
            ),
          ],
          if (amount.minor > due.minor && amount.minor > 0) ...[
            const SizedBox(height: Spacing.sm),
            AdviceNote(
              tone: AdviceTone.consequence,
              text: 'That is more than the ${due.format()} outstanding. If part of it belongs to '
                  'another invoice, record it there instead.',
            ),
          ],
          const SizedBox(height: Spacing.md),
          Text(
            'METHOD',
            style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.sm),
          SelectableTileGroup<PaymentMethod>(
            values: PaymentMethod.values,
            selected: _method,
            dense: true,
            labelOf: (method) => method.label,
            iconOf: (method) => method.icon,
            enabledOf: (_) => enabled,
            onChanged: (method) => setState(() => _method = method),
          ),
          const SizedBox(height: Spacing.md),
          LabelledField(
            label: _method.referenceLabel,
            controller: _reference,
            enabled: enabled,
            mono: true,
            uppercase: true,
            hint: switch (_method) {
              PaymentMethod.neft => 'SBIN0000123456789',
              PaymentMethod.upi => '402912345678',
              PaymentMethod.cheque => '000451',
              PaymentMethod.card => 'APPR-88213',
              PaymentMethod.cash => 'RB-2026-014',
              PaymentMethod.adjustment => 'Credit note CN/2026/0004',
            },
            helperText: _method.needsBankReference
                ? 'Without it this receipt cannot be matched to a bank statement.'
                : 'Optional for cash across the counter.',
          ),
          if (missingReference) ...[
            const SizedBox(height: Spacing.sm),
            AdviceNote(
              tone: AdviceTone.risk,
              text: 'No ${_method.referenceLabel.toLowerCase()} yet. The payment can still be '
                  'recorded, and the confirmation will say it is unreconcilable.',
            ),
          ],
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  'CLEARED ON',
                  style: context.text.labelSmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
              ),
              OutlinedButton.icon(
                onPressed: enabled ? () => unawaited(_pickDate(invoice)) : null,
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text(localTimestamp(_receivedAt.toUtc(), withTime: false)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ================================================================= parts

final class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Payments')),
        body: child,
      );
}

final class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.payment, required this.recordedBy});

  final Payment payment;
  final String recordedBy;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final reference = payment.reference?.trim();

    return DhCard(
      tone: DhCardTone.inset,
      accent: payment.isReconcilable ? context.dh.success : context.dh.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (payment.method?.trim().isNotEmpty ?? false)
                      ? payment.method!.trim().toUpperCase()
                      : 'Payment',
                  style: context.text.titleMedium,
                ),
              ),
              Text(
                payment.amount.format(),
                style: AppTheme.mono(
                  size: 15,
                  weight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          DataPairGrid(
            children: [
              DataPair.mono(label: 'Reference', value: reference ?? ''),
              DataPair.timestamp(label: 'Cleared', utc: payment.receivedAt, withTime: false),
              DataPair(label: 'Recorded by', value: recordedBy),
            ],
          ),
          if (!payment.isReconcilable) ...[
            const SizedBox(height: Spacing.sm),
            const AdviceNote(
              tone: AdviceTone.consequence,
              text: 'No reference on this receipt, so it cannot be matched to a bank statement.',
            ),
          ],
        ],
      ),
    );
  }
}
