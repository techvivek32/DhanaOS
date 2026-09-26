/// The GST tax invoice — D-004.
///
/// This document does not exist anywhere in the 46 mockups. "Confirm Dispatch" was the last wired
/// action in the corpus; every money figure was a hardcoded USD string with no currency selector;
/// there was no GSTIN, no HSN code and no tax line anywhere. Meanwhile the manufacturer is
/// "AuraForge India" and one spec screen already used Indian ring sizing. **An Indian manufacturer
/// cannot legally ship without a tax invoice**, so this is a first-class document with real rows
/// behind it rather than a PDF export bolted on later.
///
/// What the screen is careful about:
///
///  * **The supply type is derived, not asked.** GSTIN digits 1–2 are the state code; comparing
///    the customer's with the workshop's decides IGST against CGST + SGST. The operator can
///    override it, and the override is stated rather than silent.
///  * **The split is computed per line.** Jewellery is HSN 7113 at 3%, making charges at 5%,
///    certification as a service at 18% (D-003 gives the five categories those rates map from).
///    Taxing the total at one rate would produce a wrong return.
///  * **The preview is the insert.** [InvoicePreview] runs the same arithmetic
///    `draftInvoiceFromQuote` runs, so nobody issues a legal document and then finds out what it
///    said.
///  * **An issued invoice is the record.** A correction is a credit note, never an edit. Nothing
///    here writes to a stored total, and the screen says so where the edit affordance would
///    otherwise be.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/billing/amount_words.dart';
import 'package:dhanaos/features/billing/billing_actions.dart';
import 'package:dhanaos/features/billing/billing_gateway.dart';
import 'package:dhanaos/features/billing/payment_screen.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/shipping/shipping_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class InvoiceScreen extends ConsumerStatefulWidget {
  const InvoiceScreen({super.key, required this.jobId, this.invoiceId});

  final String jobId;

  /// Null opens the newest invoice on the job, or the raise form when there is none.
  final String? invoiceId;

  static Future<void> push(
    BuildContext context, {
    required String jobId,
    String? invoiceId,
  }) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => InvoiceScreen(jobId: jobId, invoiceId: invoiceId),
        ),
      );

  @override
  ConsumerState<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends ConsumerState<InvoiceScreen> {
  /// Set when the operator asks for a second invoice on a job that already has one — a deposit
  /// invoice followed by a final one is ordinary trade.
  bool _raising = false;

  /// Which invoice the document view is showing, once the operator has switched away from the
  /// default.
  String? _selected;

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
              LoadingSkeleton(height: 84),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
            ],
          ),
        ),
      ),
      error: (error, _) => _Frame(
        child: ErrorState(
          title: 'The invoice did not open',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read the billing record for this job. Check the connection '
                  'and try again.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(billingBundleProvider(widget.jobId)),
        ),
      ),
      data: (bundle) {
        final wanted = _selected ?? widget.invoiceId;
        final invoice = wanted == null
            ? bundle.issuedInvoice ?? bundle.latestInvoice
            : bundle.invoiceById(wanted);

        if (invoice == null || _raising) {
          return _RaiseForm(
            bundle: bundle,
            // Only offer a way back when there is something to go back to.
            onCancel: invoice == null ? null : () => setState(() => _raising = false),
            onRaised: (raised) => setState(() {
              _raising = false;
              _selected = raised.id;
            }),
          );
        }

        return _InvoiceDocument(
          bundle: bundle,
          invoice: invoice,
          onRaiseAnother: () => setState(() => _raising = true),
          onSelect: (id) => setState(() => _selected = id),
        );
      },
    );
  }
}

final class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Tax invoice')),
        body: child,
      );
}

// ================================================================= raise

final class _RaiseForm extends ConsumerStatefulWidget {
  const _RaiseForm({required this.bundle, required this.onRaised, this.onCancel});

  final BillingBundle bundle;
  final void Function(Invoice raised) onRaised;
  final VoidCallback? onCancel;

  @override
  ConsumerState<_RaiseForm> createState() => _RaiseFormState();
}

class _RaiseFormState extends ConsumerState<_RaiseForm> {
  late final TextEditingController _number =
      TextEditingController(text: widget.bundle.suggestedInvoiceNo);
  late final TextEditingController _placeOfSupply =
      TextEditingController(text: widget.bundle.defaultPlaceOfSupply ?? '');

  late bool _interstate = widget.bundle.defaultInterstate;
  DateTime _date = DateTime.now();

  /// True once the operator has moved the supply type off what the GSTINs imply, so the screen can
  /// stop claiming the choice was derived.
  bool _supplyOverridden = false;

  @override
  void initState() {
    super.initState();
    _number.addListener(_onTyped);
  }

  void _onTyped() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _number
      ..removeListener(_onTyped)
      ..dispose();
    _placeOfSupply.dispose();
    super.dispose();
  }

  String? get _numberProblem {
    final text = _number.text.trim();
    if (text.isEmpty) {
      return 'An invoice needs a number. The series is gapless by law, so take the suggested '
          'one unless you know better.';
    }
    return null;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(_date.year - 1),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: 'Invoice date',
    );
    if (picked == null || !mounted) return;
    setState(() => _date = picked);
  }

  Future<void> _raise() async {
    final bundle = widget.bundle;
    final quote = bundle.approvedQuote;
    final customer = bundle.customer;
    if (quote == null || customer == null) return;

    final preview = InvoicePreview.of(quote, interstate: _interstate);
    final agreed = await confirmAction(
      context,
      title: 'Raise this tax invoice?',
      message: [
        'Invoice ${_number.text.trim()} for ${preview.grandTotal.format()} against '
            '${customer.name}.',
        _interstate
            ? 'Taxed as IGST — ${preview.igst.format()} — because the place of supply is outside '
                '${bundle.sellerState ?? 'the workshop\'s state'}.'
            : 'Taxed as CGST ${preview.cgst.format()} + SGST ${preview.sgst.format()}.',
        'It is raised as a draft. Nothing is legally issued until you press Issue.',
      ].join('\n\n'),
      confirmLabel: 'Raise the draft',
      cancelLabel: 'Not yet',
    );
    if (!agreed || !mounted) return;

    try {
      final raised = await ref.read(billingActionsProvider.notifier).raise(
            jobId: bundle.job.id,
            customerId: customer.id,
            quoteId: quote.id,
            interstate: _interstate,
            invoiceNo: _number.text.trim(),
            placeOfSupply: _placeOfSupply.text.trim(),
            invoiceDate: _date,
          );
      if (!mounted) return;
      showDone(context, 'Draft invoice ${raised.invoiceNo} raised.');
      widget.onRaised(raised);
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bundle = widget.bundle;
    final task = ref.watch(billingActionsProvider);
    final busy = task != null;
    final permissions = ref.watch(permissionsProvider);
    final mayBill = permissions.canApprovePrice;
    final preview = bundle.previewFor(interstate: _interstate);
    final blocked = bundle.raiseBlockedReason ??
        (mayBill ? _numberProblem : permissions.blockReason(Capability.approvePrice));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Raise a tax invoice'),
        actions: [
          IconButton(
            onPressed: busy ? null : () => ref.invalidate(billingBundleProvider(bundle.job.id)),
            tooltip: 'Re-read the quote and the customer',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xl),
        children: [
          _JobLine(bundle: bundle),
          if (bundle.raiseBlockedReason != null) ...[
            const SizedBox(height: Spacing.md),
            AdviceNote(tone: AdviceTone.risk, text: bundle.raiseBlockedReason!),
          ],
          const SizedBox(height: Spacing.md),
          _PartyCard(
            title: 'Supplier',
            icon: Icons.factory_outlined,
            name: bundle.org.displayName,
            gstin: bundle.org.gstin,
            state: bundle.sellerState,
            address: ShipAddress.fromMap(bundle.org.address),
          ),
          const SizedBox(height: Spacing.md),
          if (bundle.customer != null)
            _PartyCard(
              title: 'Recipient',
              icon: Icons.storefront_outlined,
              name: bundle.customer!.name,
              gstin: bundle.customer!.gstin,
              state: GstStates.fromGstin(bundle.customer!.gstin),
              address: ShipAddress.fromCustomer(bundle.customer!),
            ),
          if (bundle.customerUnregistered) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            const AdviceNote(
              tone: AdviceTone.consequence,
              text: 'This customer has no GSTIN on file, so no input credit passes to them and '
                  'the place of supply cannot be read off a number. Check it by hand below.',
            ),
          ],
          const SizedBox(height: Spacing.md),
          _supplyCard(bundle),
          const SizedBox(height: Spacing.md),
          _numberCard(),
          if (preview != null) ...[
            const SizedBox(height: Spacing.md),
            _LineTable(preview: preview),
            const SizedBox(height: Spacing.md),
            _GstSummary(preview: preview),
          ],
        ],
      ),
      bottomNavigationBar: StickyActions(
        blockedReason: blocked,
        note: 'Raising creates a draft. The number is only claimed when it is inserted, so two '
            'operators billing at the same second will not collide silently.',
        children: [
          FilledButton.icon(
            onPressed: bundle.canRaise && mayBill && _numberProblem == null && !busy
                ? () => unawaited(_raise())
                : null,
            icon: task == BillingTask.raise
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.receipt_long_outlined, size: 18),
            label: const Text('Raise the draft invoice'),
          ),
          if (widget.onCancel != null) ...[
            const SizedBox(height: Spacing.sm),
            OutlinedButton(
              onPressed: busy ? null : widget.onCancel,
              child: const Text('Back to the invoice'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _supplyCard(BillingBundle bundle) {
    final derived = bundle.defaultInterstate;

    return DhSectionCard(
      title: 'Place of supply',
      subtitle: 'It decides whether the tax is IGST or a CGST + SGST split.',
      leading: const Icon(Icons.map_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DhSegmented<bool>(
            value: _interstate,
            label: 'Supply type',
            segments: const [
              DhSegment<bool>(
                value: false,
                label: 'Intrastate · CGST + SGST',
                icon: Icons.home_work_outlined,
              ),
              DhSegment<bool>(
                value: true,
                label: 'Interstate · IGST',
                icon: Icons.swap_horiz_rounded,
              ),
            ],
            onChanged: (value) => setState(() {
              _interstate = value;
              _supplyOverridden = value != derived;
            }),
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          AdviceNote(
            tone: _supplyOverridden ? AdviceTone.risk : AdviceTone.info,
            text: _supplyOverridden
                ? 'You have overridden what the GSTINs imply. An interstate supply taxed as CGST '
                    '— or the reverse — is a filing error, so be sure this is right.'
                : bundle.customer?.isGstRegistered ?? false
                    ? 'Read off the GSTINs: '
                        '${bundle.sellerState ?? 'the workshop'} to '
                        '${GstStates.fromGstin(bundle.customer!.gstin) ?? 'the customer'}.'
                    : 'No customer GSTIN to read, so this defaults to interstate — the '
                        'conservative choice, because under-collecting IGST is the costlier '
                        'error of the two.',
          ),
          const SizedBox(height: Spacing.md),
          LabelledField(
            label: 'Place of supply',
            controller: _placeOfSupply,
            hint: 'Maharashtra',
            helperText: 'Printed on the invoice. Prefilled from the customer\'s GSTIN.',
          ),
        ],
      ),
    );
  }

  Widget _numberCard() => DhSectionCard(
        title: 'Invoice identity',
        leading: const Icon(Icons.tag_rounded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabelledField(
              label: 'Invoice number',
              controller: _number,
              mono: true,
              hint: 'DH/2026/0001',
              helperText: 'A gapless legal series. The database holds the unique index, so a '
                  'clash is refused rather than duplicated.',
              errorText: _numberProblem,
            ),
            const SizedBox(height: Spacing.md),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'INVOICE DATE',
                    style: context.text.labelSmall
                        ?.copyWith(color: context.scheme.onSurfaceVariant),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => unawaited(_pickDate()),
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text(DateFormat('d MMM yyyy').format(_date)),
                ),
              ],
            ),
          ],
        ),
      );
}

// ================================================================= document

final class _InvoiceDocument extends ConsumerWidget {
  const _InvoiceDocument({
    required this.bundle,
    required this.invoice,
    required this.onRaiseAnother,
    required this.onSelect,
  });

  final BillingBundle bundle;
  final Invoice invoice;
  final VoidCallback onRaiseAnother;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(billingActionsProvider);
    final busy = task != null;
    final permissions = ref.watch(permissionsProvider);
    final mayBill = permissions.canApprovePrice;

    // The lines come from the quote, because `invoices` stores the totals and not the items. When
    // the quote has moved since the invoice was raised, the invoice is the record and the screen
    // has to say so rather than quietly printing today's lines under yesterday's total.
    final preview = bundle.previewFor(interstate: invoice.isInterstate);
    final linesDisagree = preview != null &&
        preview.grandTotal.currency == invoice.currency &&
        preview.grandTotal.minor != invoice.grandTotalMinor;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tax invoice'),
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
            _DocumentHeader(bundle: bundle, invoice: invoice),
            const SizedBox(height: Spacing.md),
            _JobLine(bundle: bundle),
            for (final warning in _warnings(invoice, linesDisagree: linesDisagree)) ...[
              const SizedBox(height: Spacing.sm + Spacing.xs),
              AdviceNote(tone: AdviceTone.risk, text: warning),
            ],
            const SizedBox(height: Spacing.md),
            _PartyCard(
              title: 'Supplier',
              icon: Icons.factory_outlined,
              name: bundle.org.displayName,
              gstin: bundle.org.gstin,
              state: bundle.sellerState,
              address: ShipAddress.fromMap(bundle.org.address),
            ),
            const SizedBox(height: Spacing.md),
            if (bundle.customer != null)
              _PartyCard(
                title: 'Recipient',
                icon: Icons.storefront_outlined,
                name: bundle.customer!.name,
                gstin: bundle.customer!.gstin,
                state: invoice.placeOfSupply ?? GstStates.fromGstin(bundle.customer!.gstin),
                address: ShipAddress.fromCustomer(bundle.customer!),
              ),
            if (preview != null) ...[
              const SizedBox(height: Spacing.md),
              _LineTable(
                preview: preview,
                footnote: linesDisagree
                    ? 'These lines are the current quote. The figures below are what this '
                        'invoice actually carries.'
                    : null,
              ),
            ],
            const SizedBox(height: Spacing.md),
            _StoredTotals(invoice: invoice),
            const SizedBox(height: Spacing.md),
            _PaymentSummary(
              bundle: bundle,
              invoice: invoice,
              onOpenPayments: invoice.isIssued
                  ? () => unawaited(
                        PaymentScreen.push(
                          context,
                          jobId: bundle.job.id,
                          invoiceId: invoice.id,
                        ),
                      )
                  : null,
            ),
            const SizedBox(height: Spacing.md),
            _DocumentCard(bundle: bundle, invoice: invoice, enabled: mayBill && !busy),
            if (bundle.invoices.length > 1) ...[
              const SizedBox(height: Spacing.lg),
              SectionHeading(title: 'Other invoices on this job', count: bundle.invoices.length - 1),
              const SizedBox(height: Spacing.sm + Spacing.xs),
              for (final other in bundle.invoices)
                if (other.id != invoice.id) ...[
                  DhCard(
                    tone: DhCardTone.inset,
                    onTap: () => onSelect(other.id),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            other.displayLabel,
                            style: AppTheme.mono(size: 12.5, color: context.scheme.onSurface),
                          ),
                        ),
                        StatusChip(
                          label: other.isIssued ? 'Issued' : 'Draft',
                          dense: true,
                          tone: other.isIssued ? ChipTone.success : ChipTone.neutral,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Spacing.sm),
                ],
            ],
          ],
        ),
      ),
      bottomNavigationBar: _footer(
        context,
        ref,
        task: task,
        mayBill: mayBill,
        permissions: permissions,
      ),
    );
  }

  List<String> _warnings(Invoice invoice, {required bool linesDisagree}) => <String>[
        if (!invoice.totalsBalance)
          'The tax and the total on this invoice do not add up. It cannot be issued — rebuild it '
              'from the quote.',
        if (!invoice.splitMatchesSupply)
          invoice.isInterstate
              ? 'This is an interstate supply but the invoice carries CGST and SGST. That is the '
                  'wrong document — rebuild it as IGST.'
              : 'This is an intrastate supply but the invoice carries IGST. That is the wrong '
                  'document — rebuild it as CGST + SGST.',
        if (linesDisagree)
          'The quote has changed since this invoice was raised, so the line items below no longer '
              'add up to the invoice total. The invoice is the record; a change to what is '
              'charged needs a credit note and a new invoice.',
        if (invoice.isDraft)
          'This is a draft. It carries no legal force and the piece must not ship against it.',
      ];

  Widget _footer(
    BuildContext context,
    WidgetRef ref, {
    required BillingTask? task,
    required bool mayBill,
    required Permissions permissions,
  }) {
    final busy = task != null;
    final canIssue = invoice.isDraft && invoice.totalsBalance && invoice.splitMatchesSupply;

    if (invoice.isIssued) {
      return StickyActions(
        note: 'An issued invoice is never edited. A correction is a credit note and a new '
            'invoice.',
        children: [
          FilledButton.icon(
            onPressed: busy
                ? null
                : () => unawaited(
                      PaymentScreen.push(
                        context,
                        jobId: bundle.job.id,
                        invoiceId: invoice.id,
                      ),
                    ),
            icon: const Icon(Icons.payments_outlined, size: 18),
            label: Text(
              invoice.isPaid
                  ? 'Payments'
                  : 'Record a payment · ${invoice.amountDue.format()} due',
            ),
          ),
          const SizedBox(height: Spacing.sm),
          OutlinedButton.icon(
            onPressed: busy || !mayBill ? null : onRaiseAnother,
            icon: const Icon(Icons.note_add_outlined, size: 18),
            label: const Text('Raise another invoice'),
          ),
        ],
      );
    }

    return StickyActions(
      blockedReason: mayBill
          ? (canIssue ? null : _warnings(invoice, linesDisagree: false).firstOrNull)
          : permissions.blockReason(Capability.approvePrice),
      note: 'Issuing stamps the date and makes this the document the customer and the tax '
          'authority hold.',
      children: [
        FilledButton.icon(
          onPressed: canIssue && mayBill && !busy
              ? () => unawaited(_issue(context, ref))
              : null,
          icon: task == BillingTask.issue
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.verified_outlined, size: 18),
          label: const Text('Issue the invoice'),
        ),
      ],
    );
  }

  Future<void> _issue(BuildContext context, WidgetRef ref) async {
    final agreed = await confirmAction(
      context,
      title: 'Issue invoice ${invoice.invoiceNo}?',
      message: [
        '${invoice.grandTotal.format()} to '
            '${bundle.customer?.name ?? 'the customer'}, taxed as '
            '${invoice.isInterstate ? 'IGST' : 'CGST + SGST'}.',
        amountInWords(invoice.grandTotal),
        'Once issued it cannot be edited. A correction becomes a credit note and a new invoice.',
      ].join('\n\n'),
      confirmLabel: 'Issue it',
      cancelLabel: 'Keep it a draft',
    );
    if (!agreed || !context.mounted) return;

    try {
      await ref
          .read(billingActionsProvider.notifier)
          .issue(jobId: bundle.job.id, invoice: invoice);
      if (!context.mounted) return;
      showDone(context, 'Invoice ${invoice.invoiceNo} issued.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }
}

// ================================================================= parts

final class _JobLine extends StatelessWidget {
  const _JobLine({required this.bundle});

  final BillingBundle bundle;

  @override
  Widget build(BuildContext context) {
    final job = bundle.job;
    return DhCard(
      tone: DhCardTone.inset,
      child: Row(
        children: [
          StatusChip.code(job.displayCode, dense: true),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              job.displayTitle,
              style: context.text.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (bundle.approvedQuote != null)
            StatusChip.quote(bundle.approvedQuote!.status, dense: true),
        ],
      ),
    );
  }
}

final class _DocumentHeader extends StatelessWidget {
  const _DocumentHeader({required this.bundle, required this.invoice});

  final BillingBundle bundle;
  final Invoice invoice;

  @override
  Widget build(BuildContext context) => DhCard(
        accent: invoice.isIssued ? context.dh.gold : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Tax invoice', style: context.text.headlineSmall),
                ),
                StatusChip(
                  label: invoice.isIssued ? 'Issued' : 'Draft',
                  dense: true,
                  tone: invoice.isIssued ? ChipTone.success : ChipTone.neutral,
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            DataPairGrid(
              children: [
                DataPair.mono(
                  label: 'Number',
                  value: invoice.invoiceNo,
                  emphasis: DataEmphasis.strong,
                ),
                DataPair.timestamp(
                  label: 'Date',
                  utc: invoice.invoiceDate,
                  withTime: false,
                ),
                DataPair(
                  label: 'Supply',
                  value: invoice.isInterstate ? 'Interstate · IGST' : 'Intrastate · CGST + SGST',
                ),
                DataPair(label: 'Place of supply', value: invoice.placeOfSupply ?? ''),
                if (invoice.issuedAt != null)
                  DataPair.timestamp(label: 'Issued', utc: invoice.issuedAt!),
              ],
            ),
          ],
        ),
      );
}

/// Supplier and recipient, the two parties a tax invoice must name.
final class _PartyCard extends StatelessWidget {
  const _PartyCard({
    required this.title,
    required this.icon,
    required this.name,
    required this.gstin,
    required this.state,
    required this.address,
  });

  final String title;
  final IconData icon;
  final String name;
  final String? gstin;
  final String? state;
  final ShipAddress address;

  @override
  Widget build(BuildContext context) {
    final lines = address.lines;
    final registered = (gstin?.trim().length ?? 0) >= 15;

    return DhSectionCard(
      title: title,
      leading: Icon(icon),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: context.text.titleMedium),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              Expanded(
                child: DataPair.mono(
                  label: 'GSTIN',
                  value: gstin?.trim() ?? '',
                ),
              ),
              if (!registered)
                const StatusChip(
                  label: 'Unregistered',
                  dense: true,
                  tone: ChipTone.warning,
                ),
            ],
          ),
          if (state != null) ...[
            const SizedBox(height: Spacing.sm),
            DataPair(label: 'State', value: state!),
          ],
          if (lines.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              'ADDRESS',
              style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.xs),
            for (final line in lines)
              Text(line, style: AppTheme.mono(size: 12.5, color: context.scheme.onSurface)),
          ],
        ],
      ),
    );
  }
}

/// The line items, each with its HSN code and its own rate.
final class _LineTable extends StatelessWidget {
  const _LineTable({required this.preview, this.footnote});

  final InvoicePreview preview;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;

    return DhSectionCard(
      title: 'Particulars',
      subtitle: 'HSN 7113 for articles of jewellery. Making charges and certification are taxed '
          'at their own rates.',
      leading: const Icon(Icons.list_alt_rounded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < preview.lines.length; i++) ...[
            if (i > 0) const SizedBox(height: Spacing.sm),
            _LineRow(entry: preview.lines[i]),
          ],
          if (preview.clientOwned.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            Text(
              'CLIENT-SUPPLIED MATERIAL — NOT CHARGED',
              style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.sm),
            for (final line in preview.clientOwned)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        line.label,
                        style: context.text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    Text(
                      line.declaredValueIn(preview.currency)?.format() ?? '—',
                      style: AppTheme.mono(size: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: Spacing.xs),
            AdviceNote(
              tone: AdviceTone.info,
              text: 'Declared at ${preview.clientOwnedValue.format()} for insurance. A client\'s '
                  'own stone is a custody record, not a supply, so it carries no tax.',
            ),
          ],
          if (footnote != null) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            AdviceNote(tone: AdviceTone.risk, text: footnote!),
          ],
        ],
      ),
    );
  }
}

final class _LineRow extends StatelessWidget {
  const _LineRow({required this.entry});

  final InvoiceLinePreview entry;

  @override
  Widget build(BuildContext context) {
    final line = entry.line;
    final scheme = context.scheme;
    final gst = entry.gst;

    return DhCard(
      tone: DhCardTone.inset,
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  line.label,
                  style: context.text.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                entry.taxable.format(),
                style: AppTheme.mono(
                  size: 14,
                  weight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              StatusChip.code('HSN ${entry.hsn}', dense: true),
              const SizedBox(width: Spacing.sm),
              StatusChip(label: line.category.label, dense: true),
              const Spacer(),
              Text(
                line.qtyLabel,
                style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          if (line.detail?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              line.detail!.trim(),
              style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: Spacing.xs),
          Text(
            gst.igst.isZero
                ? 'CGST ${_halfRate(entry.ratePct)} ${gst.cgst.format()}   ·   '
                    'SGST ${_halfRate(entry.ratePct)} ${gst.sgst.format()}'
                : 'IGST ${entry.rateLabel} ${gst.igst.format()}',
            style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// CGST and SGST are each half the combined rate — 1.5% + 1.5% on jewellery's 3%.
  static String _halfRate(double ratePct) {
    final half = ratePct / 2;
    final text = half == half.roundToDouble()
        ? half.toStringAsFixed(0)
        : half.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return '$text%';
  }
}

/// What raising the invoice will write.
final class _GstSummary extends StatelessWidget {
  const _GstSummary({required this.preview});

  final InvoicePreview preview;

  @override
  Widget build(BuildContext context) => DhSectionCard(
        title: 'Tax summary',
        subtitle: 'Computed per line, then summed. Nothing here is typed.',
        leading: const Icon(Icons.calculate_outlined),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AmountRow(
              label: 'Taxable value',
              amount: preview.subtotal,
              weight: AmountWeight.subtotal,
            ),
            if (preview.interstate)
              AmountRow(
                label: 'IGST',
                amount: preview.igst,
                detail: _rateDetail(preview),
              )
            else ...[
              AmountRow(
                label: 'CGST',
                amount: preview.cgst,
                detail: _rateDetail(preview, halved: true),
              ),
              AmountRow(
                label: 'SGST',
                amount: preview.sgst,
                detail: _rateDetail(preview, halved: true),
              ),
            ],
            AmountRow(
              label: 'Total payable',
              amount: preview.grandTotal,
              weight: AmountWeight.total,
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              amountInWords(preview.grandTotal),
              style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
          ],
        ),
      );

  static String? _rateDetail(InvoicePreview preview, {bool halved = false}) {
    final rates = preview.rates;
    if (rates.isEmpty) return null;
    final shown = rates.map((rate) {
      final value = halved ? rate / 2 : rate;
      return value == value.roundToDouble()
          ? '${value.toStringAsFixed(0)}%'
          : '${value.toStringAsFixed(2)}%';
    });
    return shown.join(' + ');
  }
}

/// The figures the invoice row actually holds. Stored, not derived — an issued invoice must read
/// the same next year even after a statutory rate changes.
final class _StoredTotals extends StatelessWidget {
  const _StoredTotals({required this.invoice});

  final Invoice invoice;

  @override
  Widget build(BuildContext context) => DhSectionCard(
        title: 'On this invoice',
        subtitle: 'The split is stored on the row, so this document reads the same next year.',
        leading: const Icon(Icons.receipt_outlined),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AmountRow(
              label: 'Taxable value',
              amount: invoice.subtotal,
              weight: AmountWeight.subtotal,
            ),
            if (invoice.isInterstate)
              AmountRow(label: 'IGST', amount: invoice.igst)
            else ...[
              AmountRow(label: 'CGST', amount: invoice.cgst),
              AmountRow(label: 'SGST', amount: invoice.sgst),
            ],
            AmountRow(
              label: 'Total payable',
              amount: invoice.grandTotal,
              weight: AmountWeight.total,
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              amountInWords(invoice.grandTotal),
              style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
}

final class _PaymentSummary extends StatelessWidget {
  const _PaymentSummary({
    required this.bundle,
    required this.invoice,
    required this.onOpenPayments,
  });

  final BillingBundle bundle;
  final Invoice invoice;
  final VoidCallback? onOpenPayments;

  @override
  Widget build(BuildContext context) {
    final paid = invoice.amountPaid;
    final due = invoice.amountDue;

    return DhSectionCard(
      title: 'Settlement',
      leading: const Icon(Icons.account_balance_outlined),
      action: StatusChip(
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AmountRow(label: 'Invoiced', amount: invoice.grandTotal),
          AmountRow(label: 'Received', amount: paid),
          AmountRow(
            label: 'Outstanding',
            amount: due,
            weight: AmountWeight.total,
            valueColor: due.isZero ? context.dh.success : null,
          ),
          if (invoice.payments.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            for (final payment in invoice.payments)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        payment.displayLabel,
                        style: AppTheme.mono(size: 11.5, color: context.scheme.onSurfaceVariant),
                      ),
                    ),
                    Text(
                      localTimestamp(payment.receivedAt, withTime: false),
                      style: AppTheme.mono(
                        size: 10.5,
                        color: context.scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (onOpenPayments != null) ...[
            const SizedBox(height: Spacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onOpenPayments,
                icon: const Icon(Icons.payments_outlined, size: 18),
                label: const Text('Open payments'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The signed or stamped copy. The row already holds every figure, so this is the paper trail
/// rather than the invoice itself.
final class _DocumentCard extends ConsumerWidget {
  const _DocumentCard({
    required this.bundle,
    required this.invoice,
    required this.enabled,
  });

  final BillingBundle bundle;
  final Invoice invoice;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pdf = bundle.fileOf(invoice.pdfAttachment);

    return DhSectionCard(
      title: 'Signed copy',
      subtitle: 'Optional. Attach the stamped or digitally signed PDF once it exists.',
      leading: const Icon(Icons.picture_as_pdf_outlined),
      child: pdf != null
          ? AttachmentTile.row(
              item: attachmentViewOf(pdf),
              onRetake: enabled ? () => unawaited(_attach(context, ref)) : null,
            )
          : OutlinedButton.icon(
              onPressed: enabled ? () => unawaited(_attach(context, ref)) : null,
              icon: const Icon(Icons.upload_file_rounded, size: 18),
              label: const Text('Attach the signed PDF'),
            ),
    );
  }

  Future<void> _attach(BuildContext context, WidgetRef ref) async {
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: 'Signed tax invoice',
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
      );
    } on Exception catch (error) {
      if (!context.mounted) return;
      showFailure(
        context,
        StorageFailure(
          message: 'The file browser could not be opened. Check that DhanaOS has file '
              'permission.',
          detail: error.toString(),
        ),
      );
      return;
    }
    final chosen = picked;
    if (chosen == null || !context.mounted) return;
    final path = chosen.path;
    if (path == null) {
      showFailure(
        context,
        const StorageFailure(
          message: 'That file has no local copy this build can stream. Save it to the device '
              'first, then attach it.',
          code: 'no_local_path',
        ),
      );
      return;
    }

    try {
      await ref.read(billingActionsProvider.notifier).attachPdf(
            jobId: bundle.job.id,
            invoice: invoice,
            document: InvoiceDocument(path: path, filename: chosen.name),
          );
      if (!context.mounted) return;
      showDone(context, 'Signed copy attached to ${invoice.invoiceNo}.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }
}
