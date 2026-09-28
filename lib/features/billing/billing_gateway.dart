/// The read layer behind the tax invoice and the payments against it.
///
/// D-004, and the single largest hole in the corpus: **there was no invoice at all.** "Confirm
/// Dispatch" was the last wired action in all 46 screens, every money figure was a hardcoded USD
/// string with no currency selector, and the manufacturer is an Indian entity that cannot legally
/// ship without a tax invoice. So this whole area is net-new, and three things it needs are things
/// no other surface in the app loads:
///
///  * **the org**, because a tax invoice names the *seller* — legal name, GSTIN, address — and
///    `Org.canRaiseTaxInvoice` is what decides whether one can be raised at all;
///  * **the customer's GSTIN**, because its first two digits are the state code, and comparing it
///    with the org's is what decides IGST against CGST + SGST. The invoice never has to ask the
///    operator "is this interstate?";
///  * **the approved quote with its cost lines**, because the split is computed per line — HSN
///    7113 jewellery at 3%, making charges at 5%, certification as a service at 18% — and not on
///    the total.
///
/// [InvoicePreview] deliberately mirrors `QuoteRepository.draftInvoiceFromQuote` line for line.
/// The screen shows the operator exactly the figures the insert will write, so nobody issues a
/// legal document and then discovers what it said.
library;

import 'package:collection/collection.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/customer_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/quote_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'billing_gateway.g.dart';

// ================================================================= place of supply

/// GST state codes — the first two digits of a GSTIN.
///
/// `invoices.place_of_supply` is free text, and a free-text legal field filled in from memory is
/// how an invoice ends up filed against the wrong state. The customer's own GSTIN already carries
/// the answer, so it is read off there.
abstract final class GstStates {
  static const byCode = <String, String>{
    '01': 'Jammu and Kashmir',
    '02': 'Himachal Pradesh',
    '03': 'Punjab',
    '04': 'Chandigarh',
    '05': 'Uttarakhand',
    '06': 'Haryana',
    '07': 'Delhi',
    '08': 'Rajasthan',
    '09': 'Uttar Pradesh',
    '10': 'Bihar',
    '11': 'Sikkim',
    '12': 'Arunachal Pradesh',
    '13': 'Nagaland',
    '14': 'Manipur',
    '15': 'Mizoram',
    '16': 'Tripura',
    '17': 'Meghalaya',
    '18': 'Assam',
    '19': 'West Bengal',
    '20': 'Jharkhand',
    '21': 'Odisha',
    '22': 'Chhattisgarh',
    '23': 'Madhya Pradesh',
    '24': 'Gujarat',
    '26': 'Dadra and Nagar Haveli and Daman and Diu',
    '27': 'Maharashtra',
    '29': 'Karnataka',
    '30': 'Goa',
    '31': 'Lakshadweep',
    '32': 'Kerala',
    '33': 'Tamil Nadu',
    '34': 'Puducherry',
    '35': 'Andaman and Nicobar Islands',
    '36': 'Telangana',
    '37': 'Andhra Pradesh',
    '38': 'Ladakh',
    '97': 'Other Territory',
  };

  /// The state a GSTIN belongs to, or null when the number is absent or malformed.
  static String? fromGstin(String? gstin) {
    final trimmed = gstin?.trim();
    if (trimmed == null || trimmed.length < 2) return null;
    return byCode[trimmed.substring(0, 2)];
  }
}

// ================================================================= the preview

/// One cost line as it will appear on the invoice, with its own tax split.
final class InvoiceLinePreview {
  const InvoiceLinePreview({required this.line, required this.gst});

  final CostLine line;
  final GstBreakdown gst;

  Money get taxable => gst.taxable;

  Money get tax => gst.tax;

  Money get total => gst.total;

  /// D-004: jewellery is HSN 7113. The model falls back to it rather than to blank, because a
  /// line with no HSN is an invoice a tax officer will reject.
  String get hsn => line.effectiveHsnCode;

  /// The statutory rate for the category when the line does not carry its own.
  double get ratePct => line.effectiveTaxRatePct;

  /// '3%' / '18%'.
  String get rateLabel =>
      '${ratePct == ratePct.roundToDouble() ? ratePct.toStringAsFixed(0) : ratePct}%';
}

/// Exactly what raising the invoice will write.
final class InvoicePreview {
  const InvoicePreview({
    required this.currency,
    required this.interstate,
    required this.lines,
    required this.clientOwned,
    required this.subtotal,
    required this.cgst,
    required this.sgst,
    required this.igst,
    required this.grandTotal,
  });

  /// Build it from the approved quote, the same way `fn_recalc_quote` and
  /// `draftInvoiceFromQuote` do: per line, and skipping anything the client owns.
  factory InvoicePreview.of(Quote quote, {required bool interstate}) {
    final currency = quote.currency;
    var subtotal = Money(0, currency);
    var cgst = Money(0, currency);
    var sgst = Money(0, currency);
    var igst = Money(0, currency);
    final lines = <InvoiceLinePreview>[];
    final clientOwned = <CostLine>[];

    for (final line in quote.lines.sorted((a, b) => a.position.compareTo(b.position))) {
      if (line.isClientOwned) {
        // A client's own stone is a declared value for insurance, not a supply to be taxed.
        clientOwned.add(line);
        continue;
      }
      final split = line.gst(currency: currency, interstate: interstate);
      lines.add(InvoiceLinePreview(line: line, gst: split));
      subtotal += split.taxable;
      cgst += split.cgst;
      sgst += split.sgst;
      igst += split.igst;
    }

    return InvoicePreview(
      currency: currency,
      interstate: interstate,
      lines: lines,
      clientOwned: clientOwned,
      subtotal: subtotal,
      cgst: cgst,
      sgst: sgst,
      igst: igst,
      grandTotal: subtotal + cgst + sgst + igst,
    );
  }

  final String currency;
  final bool interstate;
  final List<InvoiceLinePreview> lines;

  /// Shown but never charged. The mockups had a `Reset Stone` job type and a "Verified & Logged
  /// in Inventory" chip with no record behind either; a client-owned line on the invoice is where
  /// that custody finally becomes visible to the customer.
  final List<CostLine> clientOwned;

  final Money subtotal;
  final Money cgst;
  final Money sgst;
  final Money igst;
  final Money grandTotal;

  Money get tax => cgst + sgst + igst;

  bool get isEmpty => lines.isEmpty;

  /// The declared value of everything the client supplied, for the insurance note.
  Money get clientOwnedValue {
    var total = Money(0, currency);
    for (final line in clientOwned) {
      total += line.declaredValueIn(currency) ?? Money(0, currency);
    }
    return total;
  }

  /// The rates in play, for the summary line — an invoice mixing 3% and 18% should say so.
  List<double> get rates {
    final seen = <double>{for (final line in lines) line.ratePct};
    return seen.toList()..sort();
  }
}

// ================================================================= the bundle

/// Everything the invoice and payment screens open with.
final class BillingBundle {
  const BillingBundle({
    required this.job,
    required this.org,
    required this.customer,
    required this.quotes,
    required this.invoices,
    required this.people,
    required this.files,
    required this.suggestedInvoiceNo,
  });

  final Job job;

  /// The seller. Its GSTIN is what makes a tax invoice possible at all.
  final Org org;

  /// The buyer. Null on a job with no customer, which blocks invoicing outright.
  final Customer? customer;

  /// Newest version first, each with its cost lines.
  final List<Quote> quotes;

  /// Newest invoice date first, each with its payments.
  final List<Invoice> invoices;

  /// Whoever recorded a payment, keyed by id. D-008: a name on screen came off a row.
  final Map<String, AppUser> people;

  /// Signed invoice PDFs, keyed by attachment id.
  final Map<String, Attachment> files;

  /// The next number in this year's series. Only a suggestion — the unique index on
  /// `(org_id, invoice_no)` is the arbiter, and a collision comes back as a duplicate with a
  /// fresh suggestion.
  final String suggestedInvoiceNo;

  // -------------------------------------------------------------- quotes

  /// The version the customer actually approved — the only one that may be invoiced.
  Quote? get approvedQuote =>
      quotes.firstWhereOrNull((quote) => quote.status == QuoteStatus.approved);

  Quote? get latestQuote => quotes.firstOrNull;

  String get currency => approvedQuote?.currency ?? job.currency;

  // -------------------------------------------------------------- invoices

  Invoice? get latestInvoice => invoices.firstOrNull;

  Invoice? get issuedInvoice => invoices.firstWhereOrNull((i) => i.isIssued);

  Invoice? invoiceById(String id) => invoices.firstWhereOrNull((i) => i.id == id);

  bool get hasIssuedInvoice => issuedInvoice != null;

  /// Every issued invoice's total. A job can carry more than one — a deposit invoice and a final
  /// one — so this is a sum, not a lookup.
  Money get billed {
    var total = Money(0, currency);
    for (final invoice in invoices) {
      if (!invoice.isIssued || invoice.currency != currency) continue;
      total += invoice.grandTotal;
    }
    return total;
  }

  Money get received {
    var total = Money(0, currency);
    for (final invoice in invoices) {
      if (!invoice.isIssued || invoice.currency != currency) continue;
      total += invoice.amountPaid;
    }
    return total;
  }

  Money get outstanding {
    final due = billed - received;
    return due.isNegative ? Money(0, currency) : due;
  }

  // -------------------------------------------------------------- raising

  /// Interstate supply is IGST; intrastate splits into CGST + SGST. An unknown state code falls
  /// back to interstate, the conservative choice — under-collecting IGST is the costlier error.
  bool get defaultInterstate => customer?.isInterstateFrom(org.gstin) ?? true;

  /// The buyer's state, read off their GSTIN, falling back to their address.
  String? get defaultPlaceOfSupply {
    final fromGstin = GstStates.fromGstin(customer?.gstin);
    if (fromGstin != null) return fromGstin;
    final address = customer?.address;
    if (address == null) return null;
    final state = address['state'];
    return state is String && state.trim().isNotEmpty ? state.trim() : null;
  }

  /// The seller's own state, for the header.
  String? get sellerState => GstStates.fromGstin(org.gstin);

  /// Whether a tax invoice can be raised right now.
  bool get canRaise => raiseBlockedReason == null;

  /// Why it cannot, phrased as the fix. Convention 8: naming what is missing is the fix;
  /// "cannot raise invoice" is not.
  String? get raiseBlockedReason {
    if (!org.canRaiseTaxInvoice) {
      return 'The workshop has no GSTIN on file, and a tax invoice cannot be raised without one. '
          'Add it under Settings first.';
    }
    if (customer == null) {
      return 'This job has no customer attached, so there is nobody to invoice. Attach the '
          'customer on the job order.';
    }
    final approved = approvedQuote;
    if (approved == null) {
      final latest = latestQuote;
      return latest == null
          ? 'This job has no quote yet. Price it and get the quote approved before invoicing.'
          : 'Quote v${latest.version} is ${latest.status.label.toLowerCase()}. Only an approved '
              'quote can be invoiced.';
    }
    if (approved.lines.isEmpty) {
      return 'Quote v${approved.version} has no cost lines, so there is nothing to invoice.';
    }
    if (InvoicePreview.of(approved, interstate: defaultInterstate).isEmpty) {
      return 'Every line on quote v${approved.version} is client-supplied material. There is no '
          'chargeable supply on this job, so there is nothing to tax.';
    }
    return null;
  }

  /// What raising it will write, at the chosen supply type.
  InvoicePreview? previewFor({required bool interstate}) {
    final approved = approvedQuote;
    return approved == null
        ? null
        : InvoicePreview.of(approved, interstate: interstate);
  }

  /// A warning worth repeating on the invoice screen: the customer is not GST registered, so no
  /// input credit passes to them and the place of supply had to be guessed.
  bool get customerUnregistered => !(customer?.isGstRegistered ?? false);

  // -------------------------------------------------------------- lookups

  AppUser? person(String? id) => id == null ? null : people[id];

  String nameFor(String? id, {String fallback = 'Unrecorded'}) =>
      person(id)?.fullName ?? fallback;

  Attachment? fileOf(String? id) => id == null ? null : files[id];
}

// ================================================================= gateway

final class BillingGateway {
  const BillingGateway(this._client, this._jobs, this._customers, this._quotes);

  final SupabaseClient _client;
  final JobRepository _jobs;
  final CustomerRepository _customers;
  final QuoteRepository _quotes;

  static const _peopleSelect = 'id, org_id, principal, full_name, title, initials, email, '
      'phone, avatar_path, is_active, created_at';

  /// Everything the two billing screens render.
  ///
  /// Sequential on purpose: a `.wait` would replace a [DhFailure] — which carries the server's own
  /// operator-facing sentence — with a `ParallelWaitError`, and those sentences are the product.
  Future<BillingBundle> bundle(String jobId) async {
    final job = await _jobs.getJob(jobId);
    final org = await _org(job.orgId);
    final customerId = job.customerId;
    final customer = customerId == null ? null : await _customers.findCustomer(customerId);
    final quotes = await _quotes.quotes(jobId);
    final invoices = await _quotes.invoices(jobId: jobId);
    final suggested = await _quotes.suggestInvoiceNo();

    final people = await _peopleFor(<String?>[
      for (final invoice in invoices)
        for (final payment in invoice.payments) payment.recordedBy,
    ]);
    final files = await _filesFor(<String?>[
      for (final invoice in invoices) invoice.pdfAttachment,
    ]);

    return BillingBundle(
      job: job,
      org: org,
      customer: customer,
      quotes: quotes,
      invoices: invoices,
      people: people,
      files: files,
      suggestedInvoiceNo: suggested,
    );
  }

  /// The seller on the invoice. Read here because no other surface needs the org row, and a tax
  /// invoice without the seller's legal name and GSTIN is not a tax invoice.
  Future<Org> _org(String orgId) async {
    final row = await guard(
      () => _client.from('orgs').select().eq('id', orgId).single(),
    );
    return Org.fromJson(row);
  }

  Future<Map<String, AppUser>> _peopleFor(Iterable<String?> ids) async {
    final wanted = <String>{for (final id in ids) if (id != null) id};
    if (wanted.isEmpty) return const <String, AppUser>{};
    final rows = await guard(
      () => _client.from('app_users').select(_peopleSelect).inFilter('id', wanted.toList()),
    );
    final out = <String, AppUser>{};
    for (final row in rows) {
      final user = AppUser.fromJson(row);
      out[user.id] = user;
    }
    return out;
  }

  Future<Map<String, Attachment>> _filesFor(Iterable<String?> ids) async {
    final wanted = <String>{for (final id in ids) if (id != null) id};
    if (wanted.isEmpty) return const <String, Attachment>{};
    final rows = await guard(
      () => _client.from('attachments').select().inFilter('id', wanted.toList()),
    );
    final out = <String, Attachment>{};
    for (final row in rows) {
      final file = Attachment.fromJson(row);
      out[file.id] = file;
    }
    return out;
  }
}

// ================================================================= providers

@Riverpod(keepAlive: true)
BillingGateway billingGateway(Ref ref) => BillingGateway(
      ref.watch(supabaseProvider),
      ref.watch(jobRepositoryProvider),
      ref.watch(customerRepositoryProvider),
      ref.watch(quoteRepositoryProvider),
    );

/// Re-read on demand rather than live. Issuing an invoice is irreversible — a correction is a
/// credit note, not an edit — so the figures must not shuffle under the operator mid-decision.
/// Every billing action invalidates this when it lands.
@riverpod
Future<BillingBundle> billingBundle(Ref ref, String jobId) =>
    ref.watch(billingGatewayProvider).bundle(jobId);
