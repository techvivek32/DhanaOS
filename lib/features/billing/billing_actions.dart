/// Every write the billing tail makes, in one place, with one busy flag.
///
/// Three rules shape this file, and none of them is re-implemented here — each lives where it
/// belongs and this only asks:
///
///  * **Only an approved quote can be invoiced.** `draftInvoiceFromQuote` refuses otherwise, in
///    its own words. The button is held shut by [BillingBundle.canRaise] so the refusal is a
///    backstop rather than the experience.
///  * **An issued invoice is immutable.** `issueInvoice` checks that the parts add up and that the
///    CGST/SGST/IGST split matches the place of supply before it stamps `issued_at` — an
///    interstate invoice carrying CGST is a real filing error, not a cosmetic one. A correction is
///    a credit note, never an edit, which is why nothing here updates a stored total.
///  * **Money received is its own row.** `recordPayment` refuses a non-positive amount, an
///    unissued invoice and a currency mismatch. A receipt in the wrong currency is reconciled
///    separately, never summed.
///
/// Raising or issuing an invoice also invalidates the shipping bundle, because the packing bench
/// is told there that an Indian manufacturer cannot legally ship without one (D-004) — and a
/// warning that stays up after it has been dealt with teaches operators to ignore warnings.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/quote_repository.dart';
import 'package:dhanaos/data/repositories/thread_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/billing/billing_gateway.dart';
import 'package:dhanaos/features/shipping/shipping_gateway.dart';

part 'billing_actions.g.dart';

/// Which write is in flight, so the screen spins the control that was pressed.
enum BillingTask { raise, issue, recordPayment, attachPdf }

/// A file on its way to an invoice — the signed PDF, or a scan of the stamped copy.
final class InvoiceDocument {
  const InvoiceDocument({required this.path, required this.filename});

  final String path;
  final String filename;
}

@Riverpod(keepAlive: true)
class BillingActions extends _$BillingActions {
  /// Null when nothing is in flight.
  @override
  BillingTask? build() => null;

  bool get isBusy => state != null;

  bool isRunning(BillingTask task) => state == task;

  QuoteRepository get _quotes => ref.read(quoteRepositoryProvider);

  // -------------------------------------------------------------- raise

  /// Build the tax invoice from the approved quote.
  ///
  /// The split is computed per cost line, not on the total, because the categories carry
  /// different statutory rates — jewellery at 3%, making charges at 5%, certification as a
  /// service at 18%. [InvoicePreview] showed the operator those exact figures before they pressed
  /// anything.
  Future<Invoice> raise({
    required String jobId,
    required String customerId,
    required String quoteId,
    required bool interstate,
    required String invoiceNo,
    String? placeOfSupply,
    DateTime? invoiceDate,
  }) async {
    state = BillingTask.raise;
    try {
      return await _quotes.draftInvoiceFromQuote(
        quoteId: quoteId,
        customerId: customerId,
        isInterstate: interstate,
        invoiceNo: invoiceNo,
        placeOfSupply: placeOfSupply,
        invoiceDate: invoiceDate,
      );
    } finally {
      state = null;
      _after(jobId);
    }
  }

  // -------------------------------------------------------------- issue

  /// Stamp it issued. After this the document is what the customer and the tax authority hold.
  Future<Invoice> issue({required String jobId, required Invoice invoice}) async {
    state = BillingTask.issue;
    try {
      final issued = await _quotes.issueInvoice(invoice.id);
      await _note(
        jobId: jobId,
        // The invoice is the customer's document, so it belongs in the feed they can see.
        isInternal: false,
        body: 'Tax invoice ${issued.invoiceNo} issued for ${issued.grandTotal.format()} '
            '(${issued.isInterstate ? 'IGST' : 'CGST + SGST'}).',
      );
      return issued;
    } finally {
      state = null;
      _after(jobId);
    }
  }

  // -------------------------------------------------------------- payments

  /// Record money actually received.
  ///
  /// A receipt with no reference cannot be matched to a bank statement
  /// ([Payment.isReconcilable]), so the screen asks for the UTR or cheque number even though the
  /// column allows null — and says so in the confirmation when it is left blank.
  Future<Payment> recordPayment({
    required String jobId,
    required Invoice invoice,
    required Money amount,
    String? method,
    String? reference,
    DateTime? receivedAt,
  }) async {
    state = BillingTask.recordPayment;
    try {
      final payment = await _quotes.recordPayment(
        invoiceId: invoice.id,
        amount: amount,
        method: method,
        reference: reference,
        receivedAt: receivedAt,
      );
      final remaining = invoice.amountDue - amount;
      await _note(
        jobId: jobId,
        isInternal: false,
        body: [
          '${amount.format()} received against invoice ${invoice.invoiceNo}'
              '${method == null || method.trim().isEmpty ? '' : ' by ${method.trim().toUpperCase()}'}.',
          if (reference != null && reference.trim().isNotEmpty)
            'Reference ${reference.trim()}.',
          remaining.isNegative || remaining.isZero
              ? 'The invoice is settled in full.'
              : '${remaining.format()} still outstanding.',
        ].join(' '),
      );
      return payment;
    } finally {
      state = null;
      _after(jobId);
    }
  }

  // -------------------------------------------------------------- documents

  /// Attach the signed or stamped copy.
  ///
  /// The row already holds every figure, so this is the paper trail rather than the invoice
  /// itself — which is exactly the right way round, and the opposite of a system whose invoice is
  /// a PDF export with no data behind it.
  Future<Invoice> attachPdf({
    required String jobId,
    required Invoice invoice,
    required InvoiceDocument document,
  }) async {
    state = BillingTask.attachPdf;
    try {
      final orgId = ref.read(repoIdentityProvider).requireOrgId();
      final uploaded = await ref.read(attachmentStoreProvider).upload(
            UploadRequest.file(
              orgId: orgId,
              kind: AttachmentKind.invoice,
              file: _fileAt(document.path),
              filename: document.filename,
              jobId: jobId,
              caption: 'Tax invoice ${invoice.invoiceNo}',
            ),
          );
      return await _quotes.attachInvoicePdf(
        invoiceId: invoice.id,
        attachmentId: uploaded.id,
      );
    } finally {
      state = null;
      _after(jobId);
    }
  }

  // -------------------------------------------------------------- plumbing

  /// Kept separate so the `dart:io` dependency does not leak into the public signature — the
  /// screens hand over a path and a name, which is what both pickers give them.
  static File _fileAt(String path) => File(path);

  /// A billing event writes to the digital thread as well as to the row: `job_detail`'s core
  /// mechanic is one chronological stream, and an invoice issued with nothing in the feed is
  /// invisible to everyone not standing on this screen.
  ///
  /// `stage` is deliberately left null. Invoicing is a commercial act, not a rail position, and
  /// tagging it to whatever stage the bench happened to be at would put a misleading label on it.
  ///
  /// A failure here is swallowed: the invoice was issued, and reporting "issuing failed" because
  /// a note did not post would send the operator back to issue a document that already exists.
  Future<void> _note({
    required String jobId,
    required String body,
    bool isInternal = true,
  }) async {
    try {
      await ref.read(threadRepositoryProvider).postMessage(
            jobId: jobId,
            body: body,
            isInternal: isInternal,
          );
    } on DhFailure catch (_) {
      // Nothing useful to do. The row is written; the feed catches up on the next post.
    }
  }

  /// Re-read after every write, including a failed one — `attachPdf` uploads before it links, so
  /// a failure on the second half still changed storage.
  void _after(String jobId) {
    ref.invalidate(billingBundleProvider(jobId));
    ref.invalidate(jobInvoicesProvider(jobId));
    ref.invalidate(jobSnapshotProvider(jobId));
    // The packing bench is told there that the piece cannot legally ship without this document.
    ref.invalidate(shippingBundleProvider(jobId));
  }
}
