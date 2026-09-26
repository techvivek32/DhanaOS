/// Typed data access for money: quotes and their cost lines, metal rates, approval gates, GST
/// invoices and payments.
///
/// The mockups had no pricing engine at all. Every money figure was hardcoded text, the
/// commercial screen had zero inputs, its four cost lines summed to `$970` and no screen ever
/// displayed that total. The utilisation bar was literally `style="width: 85%"` when the real
/// figure was 90.8%. So almost everything here is net-new, and three rules shape it:
///
///  * **Totals belong to the database.** `fn_recalc_quote` fires on every `cost_lines` write and
///    rewrites `subtotal` / `tax_total` / `grand_total`. Every mutation in this file therefore
///    *re-reads the quote* and returns it, rather than computing a total in Dart and writing it
///    back. Two devices editing one quote cannot then disagree about what it costs.
///  * **Money is [Money]** — integer minor units plus an ISO-4217 code (D-004). A quote is
///    single-currency by construction: a cost line has no currency of its own, so passing a
///    [Money] in the wrong currency is a caller bug and is refused as one.
///  * **GST is stored, not derived at render time** (D-004). An issued invoice must read the
///    same next year even after a statutory rate changes, so the CGST/SGST/IGST split is
///    computed once from the quote's lines and written into the invoice row.
///
/// `fn_commit_job` refuses to mint a job code while any approval gate is unapproved. The gates
/// live here; committing the job is the job repository's call.
library;

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'quote_repository.g.dart';

/// `quotes.valid_until` and `invoices.invoice_date` are `date` columns: a calendar day, not an
/// instant. A UTC timestamp would move the day for half the clock.
final _wireDate = DateFormat('yyyy-MM-dd');

final class QuoteRepository {
  const QuoteRepository(this._client, this._identity);

  final SupabaseClient _client;

  /// D-008: `org_id` and the actor come from the signed-in operator's `app_users` row and from
  /// nowhere else. A repository never invents either.
  final RepoIdentity _identity;

  /// A quote is never useful without its lines: the five-category breakdown (D-003) is what a
  /// customer actually approves.
  static const _quoteSelect = '*, cost_lines(*)';

  static const _invoiceSelect = '*, payments(*)';

  String get _org => _identity.requireOrgId();

  /// Who approved the price. An irreversible commercial decision attributed to nobody is worth
  /// nothing, so an unauthenticated write is refused rather than left blank.
  String get _actor => _identity.requireUserId();

  // -------------------------------------------------------------- quotes

  /// Newest version first. Versions are kept, never overwritten — a customer who approved v2 did
  /// not approve v3.
  Future<List<Quote>> quotes(String jobId) async {
    final rows = await guard(
      () => _client
          .from('quotes')
          .select(_quoteSelect)
          .eq('job_id', jobId)
          .order('version', ascending: false)
          .order('position', ascending: true, referencedTable: 'cost_lines'),
    );
    return [for (final row in rows) Quote.fromJson(row)];
  }

  Future<Quote> quote(String quoteId) async {
    final row = await guard(
      () => _client
          .from('quotes')
          .select(_quoteSelect)
          .eq('id', quoteId)
          .order('position', ascending: true, referencedTable: 'cost_lines')
          .single(),
    );
    return Quote.fromJson(row);
  }

  Future<Quote?> latestQuote(String jobId) async {
    final row = await guard(
      () => _client
          .from('quotes')
          .select(_quoteSelect)
          .eq('job_id', jobId)
          .order('version', ascending: false)
          .order('position', ascending: true, referencedTable: 'cost_lines')
          .limit(1)
          .maybeSingle(),
    );
    return row == null ? null : Quote.fromJson(row);
  }

  /// The version the customer agreed to, which is what an invoice is built from.
  Future<Quote?> approvedQuote(String jobId) async {
    final row = await guard(
      () => _client
          .from('quotes')
          .select(_quoteSelect)
          .eq('job_id', jobId)
          .eq('status', QuoteStatus.approved.wire)
          .order('version', ascending: false)
          .order('position', ascending: true, referencedTable: 'cost_lines')
          .limit(1)
          .maybeSingle(),
    );
    return row == null ? null : Quote.fromJson(row);
  }

  /// Start a new version. The version number is the next after the highest this job has, so
  /// re-pricing after a rejection never overwrites the record of what was refused.
  ///
  /// A draft is allowed to be unfinished — a `costPlus` basis with no margin yet is a normal
  /// halfway state. [sendQuote] is where that becomes a refusal.
  ///
  /// Passing [metalRateId] locks the rate, which is the "Locked Rate" badge the mockup drew with
  /// no field behind it to timestamp.
  Future<Quote> createQuote({
    required String jobId,
    PricingBasis basis = PricingBasis.fixed,
    String currency = 'INR',
    double? marginPct,
    Money? targetUnitPrice,
    Money? maxApproved,
    DateTime? validUntil,
    String? metalRateId,
  }) async {
    _assertCurrency(targetUnitPrice, currency, 'targetUnitPrice');
    _assertCurrency(maxApproved, currency, 'maxApproved');

    final existing = await guard(
      () => _client
          .from('quotes')
          .select('version')
          .eq('job_id', jobId)
          .order('version', ascending: false)
          .limit(1)
          .maybeSingle(),
    );
    final version = (existing?['version'] as int? ?? 0) + 1;

    final row = await guard(
      () => _client
          .from('quotes')
          .insert(<String, dynamic>{
            'job_id': jobId,
            'version': version,
            'status': QuoteStatus.draft.wire,
            // Convention 6: the Postgres value, never `.name`.
            'basis': basis.wire,
            'margin_pct': marginPct,
            'currency': currency,
            'metal_rate_id': metalRateId,
            'rate_locked_at': metalRateId == null ? null : _now(),
            'target_unit_price': targetUnitPrice?.minor,
            'max_approved': maxApproved?.minor,
            'valid_until': validUntil == null ? null : _wireDate.format(validUntil),
          })
          .select('id')
          .single(),
    );
    return quote(row['id'] as String);
  }

  /// The commercial envelope and the pricing basis. Omitted arguments are left alone.
  Future<Quote> updateQuoteTerms({
    required String quoteId,
    PricingBasis? basis,
    double? marginPct,
    Money? targetUnitPrice,
    Money? maxApproved,
    DateTime? validUntil,
  }) async {
    final current = await quote(quoteId);
    _assertCurrency(targetUnitPrice, current.currency, 'targetUnitPrice');
    _assertCurrency(maxApproved, current.currency, 'maxApproved');

    final values = <String, dynamic>{
      if (basis != null) 'basis': basis.wire,
      if (marginPct != null) 'margin_pct': marginPct,
      if (targetUnitPrice != null) 'target_unit_price': targetUnitPrice.minor,
      if (maxApproved != null) 'max_approved': maxApproved.minor,
      if (validUntil != null) 'valid_until': _wireDate.format(validUntil),
    };
    if (values.isEmpty) return current;

    await guard(() => _client.from('quotes').update(values).eq('id', quoteId));
    return quote(quoteId);
  }

  // -------------------------------------------------------------- cost lines

  /// Add a charge. D-003: every line rolls up into exactly one of the five customer-facing
  /// categories.
  ///
  /// `amount` is written here because the schema says the app maintains it (`qty * unit_amount`,
  /// rounded once). The *quote* totals are not written: `fn_recalc_quote` owns those, and the
  /// refreshed quote that comes back carries them.
  ///
  /// [isClientOwned] flips the meaning of the money on the line: when the client owns the
  /// material it is a declared value for insurance, not a charge, and `fn_recalc_quote` leaves
  /// it out of the subtotal.
  Future<Quote> addCostLine({
    required String quoteId,
    required CostCategory category,
    required String label,
    required Money unitAmount,
    String? detail,
    SuppliedBy suppliedBy = SuppliedBy.house,
    double qty = 1,
    Uom? unit,
    String? hsnCode,
    double? taxRatePct,
    bool isClientOwned = false,
    Money? declaredValue,
    int? position,
  }) async {
    final current = await quote(quoteId);
    _assertCurrency(unitAmount, current.currency, 'unitAmount');
    _assertCurrency(declaredValue, current.currency, 'declaredValue');

    final title = label.trim();
    if (title.isEmpty) {
      throw const RuleViolation(
        message: 'Name the charge. A cost line with no label is unreadable on an invoice.',
        code: 'cost_line_unlabelled',
      );
    }

    final nextPosition = position ??
        current.lines.fold<int>(-1, (top, l) => l.position > top ? l.position : top) + 1;

    await guard(
      () => _client.from('cost_lines').insert(<String, dynamic>{
        'quote_id': quoteId,
        'category': category.wire,
        'label': title,
        'detail': detail?.trim(),
        'supplied_by': suppliedBy.wire,
        'qty': qty,
        'unit': unit?.wire,
        'unit_amount': unitAmount.minor,
        // Rounded once, at the end — rounding per unit and then multiplying is how a quote
        // drifts away from its invoice.
        'amount': (unitAmount * qty).minor,
        'hsn_code': hsnCode?.trim() ?? '7113',
        // D-004: falls back to the statutory rate for the category, never to zero. A missing
        // rate that silently means "no tax" is how an invoice becomes illegal.
        'tax_rate_pct': taxRatePct ?? GstRates.forCategory(category.wire),
        'is_client_owned': isClientOwned,
        'declared_value': declaredValue?.minor,
        'position': nextPosition,
      }),
    );
    return quote(quoteId);
  }

  /// Edit a line. Omitted arguments are left alone; pass an empty string to clear a detail.
  ///
  /// `amount` is recomputed from whichever of quantity and unit amount survives the merge, so a
  /// quantity change cannot leave a stale total on the line.
  Future<Quote> updateCostLine({
    required String quoteId,
    required String lineId,
    CostCategory? category,
    String? label,
    String? detail,
    SuppliedBy? suppliedBy,
    double? qty,
    Uom? unit,
    Money? unitAmount,
    String? hsnCode,
    double? taxRatePct,
    bool? isClientOwned,
    Money? declaredValue,
  }) async {
    final current = await quote(quoteId);
    _assertCurrency(unitAmount, current.currency, 'unitAmount');
    _assertCurrency(declaredValue, current.currency, 'declaredValue');

    final line = current.lines.where((l) => l.id == lineId).firstOrNull;
    if (line == null) {
      throw RuleViolation(
        message: 'That cost line is no longer on this quote. Reload the quote and try again.',
        detail: 'quote=$quoteId line=$lineId',
        code: 'cost_line_missing',
      );
    }

    final nextQty = qty ?? line.qty;
    final nextUnit = unitAmount ?? line.unitAmountIn(current.currency);

    await guard(
      () => _client
          .from('cost_lines')
          .update(<String, dynamic>{
            if (category != null) 'category': category.wire,
            if (label != null) 'label': label.trim(),
            if (detail != null) 'detail': _blankToNull(detail),
            if (suppliedBy != null) 'supplied_by': suppliedBy.wire,
            if (unit != null) 'unit': unit.wire,
            if (hsnCode != null) 'hsn_code': _blankToNull(hsnCode),
            if (taxRatePct != null) 'tax_rate_pct': taxRatePct,
            if (isClientOwned != null) 'is_client_owned': isClientOwned,
            if (declaredValue != null) 'declared_value': declaredValue.minor,
            'qty': nextQty,
            'unit_amount': nextUnit.minor,
            'amount': (nextUnit * nextQty).minor,
          })
          .eq('id', lineId)
          .eq('quote_id', quoteId),
    );
    return quote(quoteId);
  }

  Future<Quote> removeCostLine({
    required String quoteId,
    required String lineId,
  }) async {
    await guard(
      () => _client.from('cost_lines').delete().eq('id', lineId).eq('quote_id', quoteId),
    );
    return quote(quoteId);
  }

  /// Reorder the breakdown a customer reads top to bottom. One write per line: PostgREST has no
  /// multi-row update with differing values, and the recalc trigger is idempotent.
  Future<Quote> reorderCostLines({
    required String quoteId,
    required List<String> lineIdsInOrder,
  }) async {
    for (var i = 0; i < lineIdsInOrder.length; i++) {
      await guard(
        () => _client
            .from('cost_lines')
            .update(<String, dynamic>{'position': i})
            .eq('id', lineIdsInOrder[i])
            .eq('quote_id', quoteId),
      );
    }
    return quote(quoteId);
  }

  // -------------------------------------------------------------- quote decisions

  /// Send it out.
  ///
  /// Two refusals, both from the model's own reading of the row: a `costPlus` quote with no
  /// margin is unfinished ([Quote.needsMargin]), and a quote with no lines prices nothing.
  /// `pricing_approval` in the mockups offered only "Approve" and had neither check.
  Future<Quote> sendQuote(String quoteId) async {
    final current = await quote(quoteId);
    if (current.lines.isEmpty) {
      throw const RuleViolation(
        message: 'Add at least one cost line before sending this quote.',
        code: 'quote_empty',
      );
    }
    if (current.needsMargin) {
      throw const RuleViolation(
        message: 'Set the margin percentage. A Cost Plus quote without one has no price.',
        code: 'quote_no_margin',
      );
    }

    await guard(
      () => _client
          .from('quotes')
          .update(<String, dynamic>{
            'status': QuoteStatus.sent.wire,
            'sent_at': _now(),
          })
          .eq('id', quoteId),
    );
    return quote(quoteId);
  }

  /// Approve. Deliberately asymmetric with [rejectQuote] and [counterOffer], the same shape as
  /// D-011 rule 2: agreement owes nobody an explanation, refusal does.
  Future<Quote> approveQuote({required String quoteId, String? note}) =>
      _decide(quoteId, QuoteStatus.approved, note: note);

  /// D-006 — `pricing_approval` offered only "Approve". A rejection needs a reason, so [note] is
  /// required rather than optional.
  Future<Quote> rejectQuote({required String quoteId, required String note}) =>
      _decide(quoteId, QuoteStatus.rejected, note: note, noteRequired: true);

  /// D-006 — there was no counter-offer path and nowhere to put the number.
  Future<Quote> counterOffer({
    required String quoteId,
    required Money amount,
    required String note,
  }) async {
    final current = await quote(quoteId);
    _assertCurrency(amount, current.currency, 'amount');
    return _decide(
      quoteId,
      QuoteStatus.counterOffered,
      note: note,
      noteRequired: true,
      counterAmount: amount,
    );
  }

  Future<Quote> _decide(
    String quoteId,
    QuoteStatus status, {
    String? note,
    bool noteRequired = false,
    Money? counterAmount,
  }) async {
    final text = note?.trim();
    if (noteRequired && (text == null || text.isEmpty)) {
      throw RuleViolation(
        message: status == QuoteStatus.counterOffered
            ? 'Say what the counter-offer is based on. A number with no reasoning cannot be '
                'negotiated against.'
            : 'Say why the price was refused. Without a reason nobody can re-quote it.',
        code: 'decision_note_required',
      );
    }

    await guard(
      () => _client
          .from('quotes')
          .update(<String, dynamic>{
            'status': status.wire,
            'decided_at': _now(),
            'decided_by': _actor,
            'decision_note': text,
            if (counterAmount != null) 'counter_amount': counterAmount.minor,
          })
          .eq('id', quoteId),
    );
    return quote(quoteId);
  }

  // -------------------------------------------------------------- metal rates

  /// The rate a quote should price metal at.
  ///
  /// Exact purity first; if the shop only keeps a fine-metal rate, the purity-agnostic row is
  /// used instead and the quote scales it itself — which is what a null `purity` means in
  /// `metal_rates`. Returning nothing is a real answer: no rate means the operator has to enter
  /// one before pricing metal, and a silent zero would quote the job at the cost of the labour
  /// alone.
  Future<MetalRate?> latestMetalRate({
    required BaseMetal baseMetal,
    MetalPurity? purity,
  }) async {
    final exact = await _rateRow(baseMetal: baseMetal, purity: purity);
    if (exact != null) return MetalRate.fromJson(exact);
    if (purity == null) return null;

    final fallback = await _rateRow(baseMetal: baseMetal, purity: null);
    return fallback == null ? null : MetalRate.fromJson(fallback);
  }

  Future<Map<String, dynamic>?> _rateRow({
    required BaseMetal baseMetal,
    required MetalPurity? purity,
  }) =>
      guard(() {
        final query = _client
            .from('metal_rates')
            .select()
            .eq('org_id', _org)
            .eq('base_metal', baseMetal.wire);
        final scoped =
            purity == null ? query.isFilter('purity', null) : query.eq('purity', purity.wire);
        return scoped.order('effective_at', ascending: false).limit(1).maybeSingle();
      });

  /// Metal moves daily, so a quote that locked a rate has to be able to show how old it is
  /// ([MetalRate.isStale]). This is the history behind that.
  Future<List<MetalRate>> metalRateHistory({
    required BaseMetal baseMetal,
    MetalPurity? purity,
    int limit = 30,
  }) async {
    final rows = await guard(() {
      final query = _client
          .from('metal_rates')
          .select()
          .eq('org_id', _org)
          .eq('base_metal', baseMetal.wire);
      final scoped =
          purity == null ? query.isFilter('purity', null) : query.eq('purity', purity.wire);
      return scoped.order('effective_at', ascending: false).limit(limit);
    });
    return [for (final row in rows) MetalRate.fromJson(row)];
  }

  /// Record today's rate. `metal_rates` is insert-only for non-admins by policy, and that is
  /// correct: a rate is a snapshot, and editing yesterday's snapshot rewrites what a locked
  /// quote was priced against.
  Future<MetalRate> recordMetalRate({
    required BaseMetal baseMetal,
    required Money ratePerG,
    MetalPurity? purity,
    String source = 'manual',
    DateTime? effectiveAt,
  }) async {
    if (ratePerG.minor <= 0) {
      throw const RuleViolation(
        message: 'Enter a rate above zero. A zero rate would price the metal at nothing.',
        code: 'rate_not_positive',
      );
    }
    // D-012's dependency rule: 22K rose gold is not a product, and neither is 925 platinum.
    if (purity != null && !baseMetal.purities.contains(purity)) {
      throw RuleViolation(
        message: '${purity.label} is not a purity ${baseMetal.label.toLowerCase()} comes in. '
            'Pick one of: ${baseMetal.purities.map((p) => p.label).join(', ')}.',
        code: 'purity_mismatch',
      );
    }

    final row = await guard(
      () => _client
          .from('metal_rates')
          .insert(<String, dynamic>{
            'org_id': _org,
            'base_metal': baseMetal.wire,
            'purity': purity?.wire,
            'currency': ratePerG.currency,
            'rate_per_g': ratePerG.minor,
            'source': source.trim(),
            'effective_at': _ts(effectiveAt ?? DateTime.now()),
            'created_by': _actor,
          })
          .select()
          .single(),
    );
    return MetalRate.fromJson(row);
  }

  /// Pin a quote to a rate snapshot — the "Locked Rate" badge, with the timestamp the mockup
  /// implied and never stored.
  Future<Quote> lockMetalRate({
    required String quoteId,
    required String rateId,
  }) async {
    await guard(
      () => _client
          .from('quotes')
          .update(<String, dynamic>{
            'metal_rate_id': rateId,
            'rate_locked_at': _now(),
          })
          .eq('id', quoteId),
    );
    return quote(quoteId);
  }

  // -------------------------------------------------------------- approval gates

  /// `review_job_order` showed three gates, all "Pending", with no screen behind any of them.
  Future<List<ApprovalGate>> approvalGates(String jobId) async {
    final rows = await guard(
      () => _client
          .from('approval_gates')
          .select()
          .eq('job_id', jobId)
          .order('created_at', ascending: true),
    );
    return [for (final row in rows) ApprovalGate.fromJson(row)];
  }

  /// Make sure all three gates exist, without disturbing any that has already been decided.
  /// `ignoreDuplicates` is what keeps a re-entry into the review screen from resetting an
  /// approval to pending.
  Future<List<ApprovalGate>> ensureApprovalGates(String jobId) async {
    await guard(
      () => _client.from('approval_gates').upsert(
            <Map<String, dynamic>>[
              for (final kind in ApprovalGateKind.values)
                <String, dynamic>{'job_id': jobId, 'kind': kind.wire},
            ],
            onConflict: 'job_id,kind',
            ignoreDuplicates: true,
          ),
    );
    return approvalGates(jobId);
  }

  /// Decide one gate. `fn_commit_job` refuses to mint a job code while any gate is unapproved,
  /// so this is the write that unblocks D-001.
  Future<ApprovalGate> decideGate({
    required String gateId,
    required ApprovalGateState state,
    String? note,
  }) async {
    final text = note?.trim();
    if (state == ApprovalGateState.rejected && (text == null || text.isEmpty)) {
      throw const RuleViolation(
        message: 'Say what has to change before this gate can pass. A rejected gate with no note '
            'stops the job and explains nothing.',
        code: 'gate_note_required',
      );
    }

    final row = await guard(
      () => _client
          .from('approval_gates')
          .update(<String, dynamic>{
            'state': state.wire,
            'decided_by': state.isDecided ? _actor : null,
            'decided_at': state.isDecided ? _now() : null,
            'note': text,
          })
          .eq('id', gateId)
          .select()
          .single(),
    );
    return ApprovalGate.fromJson(row);
  }

  // -------------------------------------------------------------- invoices (D-004)

  Future<List<Invoice>> invoices({
    String? jobId,
    String? customerId,
    int limit = 50,
  }) async {
    final rows = await guard(() {
      var query = _client.from('invoices').select(_invoiceSelect);
      if (jobId != null) query = query.eq('job_id', jobId);
      if (customerId != null) query = query.eq('customer_id', customerId);
      return query.order('invoice_date', ascending: false).limit(limit);
    });
    return [for (final row in rows) Invoice.fromJson(row)];
  }

  Future<Invoice> invoice(String invoiceId) async {
    final row = await guard(
      () => _client.from('invoices').select(_invoiceSelect).eq('id', invoiceId).single(),
    );
    return Invoice.fromJson(row);
  }

  /// The next number in this year's series, as a suggestion.
  ///
  /// The unique index on `(org_id, invoice_no)` is the real arbiter — two operators billing at
  /// the same second will collide, and the second one gets a [DuplicateRecord] and a fresh
  /// suggestion. That is the right trade: a gapless legal series cannot be handed out by a
  /// client, and inventing a sequence table here would put invoice numbering in the app instead
  /// of the database.
  Future<String> suggestInvoiceNo() async {
    final year = DateTime.now().year;
    final prefix = 'DH/$year/';
    final rows = await guard(
      () => _client
          .from('invoices')
          .select('invoice_no')
          .eq('org_id', _org)
          .like('invoice_no', '$prefix%')
          .order('invoice_no', ascending: false)
          .limit(1),
    );
    final last = rows.isEmpty ? null : rows.first['invoice_no'] as String?;
    final lastSeq = last == null ? 0 : int.tryParse(last.substring(prefix.length)) ?? 0;
    return '$prefix${(lastSeq + 1).toString().padLeft(4, '0')}';
  }

  /// Build a tax invoice from the approved quote.
  ///
  /// Entirely absent from the mockups: "Confirm Dispatch" was the last wired action in all 46
  /// screens. An Indian manufacturer cannot legally ship without a tax invoice (D-004).
  ///
  /// The split is computed per line, not on the total, because the categories carry different
  /// statutory rates — jewellery at 3%, making charges at 5%, certification as a service at 18%.
  /// Client-owned lines are skipped for the same reason `fn_recalc_quote` skips them: a client's
  /// own stone is a declared value, not a supply.
  ///
  /// [isInterstate] decides IGST against CGST + SGST, and the invoice refuses to issue if the
  /// stored split ever contradicts it ([Invoice.splitMatchesSupply]).
  Future<Invoice> draftInvoiceFromQuote({
    required String quoteId,
    required String customerId,
    required bool isInterstate,
    String? invoiceNo,
    String? placeOfSupply,
    DateTime? invoiceDate,
  }) async {
    final source = await quote(quoteId);
    if (source.status != QuoteStatus.approved) {
      throw RuleViolation(
        message: 'Only an approved quote can be invoiced. Get v${source.version} approved first.',
        detail: 'quote=$quoteId status=${source.status.wire}',
        code: 'quote_not_approved',
      );
    }
    if (source.lines.isEmpty) {
      throw const RuleViolation(
        message: 'That quote has no cost lines, so there is nothing to invoice.',
        code: 'quote_empty',
      );
    }

    final currency = source.currency;
    var subtotal = Money(0, currency);
    var cgst = Money(0, currency);
    var sgst = Money(0, currency);
    var igst = Money(0, currency);

    for (final line in source.lines) {
      if (line.isClientOwned) continue;
      final split = line.gst(currency: currency, interstate: isInterstate);
      subtotal += split.taxable;
      cgst += split.cgst;
      sgst += split.sgst;
      igst += split.igst;
    }
    final grandTotal = subtotal + cgst + sgst + igst;

    final supplied = invoiceNo?.trim();
    final number =
        supplied == null || supplied.isEmpty ? await suggestInvoiceNo() : supplied;

    final row = await guard(
      () => _client
          .from('invoices')
          .insert(<String, dynamic>{
            'org_id': _org,
            'job_id': source.jobId,
            'customer_id': customerId,
            'invoice_no': number,
            'invoice_date': _wireDate.format(invoiceDate ?? DateTime.now()),
            'currency': currency,
            'place_of_supply': placeOfSupply?.trim(),
            'is_interstate': isInterstate,
            'subtotal': subtotal.minor,
            'cgst': cgst.minor,
            'sgst': sgst.minor,
            'igst': igst.minor,
            'grand_total': grandTotal.minor,
          })
          .select('id')
          .single(),
    );
    return invoice(row['id'] as String);
  }

  /// Issue it. Two integrity checks first, both cheap and both expensive to miss: the parts have
  /// to add up ([Invoice.totalsBalance]), and an interstate invoice carrying CGST — or an
  /// intrastate one carrying IGST — is the wrong document and a real filing error
  /// ([Invoice.splitMatchesSupply]).
  ///
  /// An issued invoice is immutable in practice: a correction is a credit note, not an edit.
  Future<Invoice> issueInvoice(String invoiceId) async {
    final current = await invoice(invoiceId);
    if (current.isIssued) {
      throw RuleViolation(
        message: 'Invoice ${current.invoiceNo} was already issued. Raise a credit note instead '
            'of editing it.',
        code: 'invoice_already_issued',
      );
    }
    if (!current.totalsBalance) {
      throw RuleViolation(
        message: 'The tax and the total on this invoice do not add up. Rebuild it from the quote '
            'before issuing.',
        detail: 'subtotal=${current.subtotalMinor} tax=${current.tax.minor} '
            'grand=${current.grandTotalMinor}',
        code: 'invoice_unbalanced',
      );
    }
    if (!current.splitMatchesSupply) {
      throw RuleViolation(
        message: current.isInterstate
            ? 'An interstate supply is taxed as IGST. Rebuild this invoice — it is carrying '
                'CGST and SGST.'
            : 'An intrastate supply splits into CGST and SGST. Rebuild this invoice — it is '
                'carrying IGST.',
        code: 'invoice_wrong_split',
      );
    }

    await guard(
      () => _client
          .from('invoices')
          .update(<String, dynamic>{'issued_at': _now()})
          .eq('id', invoiceId),
    );
    return invoice(invoiceId);
  }

  Future<Invoice> attachInvoicePdf({
    required String invoiceId,
    required String attachmentId,
  }) async {
    await guard(
      () => _client
          .from('invoices')
          .update(<String, dynamic>{'pdf_attachment': attachmentId})
          .eq('id', invoiceId),
    );
    return invoice(invoiceId);
  }

  // -------------------------------------------------------------- payments

  /// Money actually received. A receipt with no reference cannot be matched to a bank statement
  /// ([Payment.isReconcilable]), so the UTR or cheque number is asked for even though the column
  /// allows null.
  Future<Payment> recordPayment({
    required String invoiceId,
    required Money amount,
    String? method,
    String? reference,
    DateTime? receivedAt,
  }) async {
    if (amount.minor <= 0) {
      throw const RuleViolation(
        message: 'Enter an amount above zero. A refund is a credit note, not a negative '
            'payment.',
        code: 'payment_not_positive',
      );
    }

    final target = await invoice(invoiceId);
    if (!target.isIssued) {
      throw RuleViolation(
        message: 'Issue invoice ${target.invoiceNo} before recording money against it.',
        code: 'invoice_not_issued',
      );
    }
    if (amount.currency != target.currency) {
      throw RuleViolation(
        message: 'This invoice is in ${target.currency}. A ${amount.currency} receipt has to be '
            'reconciled separately, not summed against it.',
        code: 'payment_currency_mismatch',
      );
    }

    final row = await guard(
      () => _client
          .from('payments')
          .insert(<String, dynamic>{
            'invoice_id': invoiceId,
            'amount': amount.minor,
            'currency': amount.currency,
            'method': method?.trim().toLowerCase(),
            'reference': reference == null ? null : _blankToNull(reference),
            'received_at': _ts(receivedAt ?? DateTime.now()),
            'recorded_by': _actor,
          })
          .select()
          .single(),
    );
    return Payment.fromJson(row);
  }

  // -------------------------------------------------------------- plumbing

  /// A quote is single-currency by construction: a cost line has no currency column of its own.
  /// A mismatch is therefore a caller bug — a screen reading the wrong currency out of the job —
  /// and it is raised as one rather than dressed up as an operator error, because there is
  /// nothing the operator could do about it.
  void _assertCurrency(Money? value, String currency, String field) {
    if (value != null && value.currency != currency) {
      throw ArgumentError.value(
        value.currency,
        field,
        'does not match the quote currency $currency',
      );
    }
  }

  String _now() => DateTime.now().toUtc().toIso8601String();

  String _ts(DateTime value) => value.toUtc().toIso8601String();

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

// ---------------------------------------------------------------- providers

@Riverpod(keepAlive: true)
QuoteRepository quoteRepository(Ref ref) => QuoteRepository(
      ref.watch(supabaseProvider),
      ref.watch(repoIdentityProvider),
    );

@riverpod
Future<List<Quote>> jobQuotes(Ref ref, String jobId) =>
    ref.watch(quoteRepositoryProvider).quotes(jobId);

@riverpod
Future<Quote?> latestJobQuote(Ref ref, String jobId) =>
    ref.watch(quoteRepositoryProvider).latestQuote(jobId);

@riverpod
Future<Quote?> approvedJobQuote(Ref ref, String jobId) =>
    ref.watch(quoteRepositoryProvider).approvedQuote(jobId);

@riverpod
Future<List<ApprovalGate>> jobApprovalGates(Ref ref, String jobId) =>
    ref.watch(quoteRepositoryProvider).approvalGates(jobId);

@riverpod
Future<List<Invoice>> jobInvoices(Ref ref, String jobId) =>
    ref.watch(quoteRepositoryProvider).invoices(jobId: jobId);

/// The rate a pricing screen quotes metal at. Null means the shop has not entered one — the
/// screen must ask for it rather than pricing metal at zero.
@riverpod
Future<MetalRate?> latestMetalRate(
  Ref ref, {
  required BaseMetal baseMetal,
  MetalPurity? purity,
}) =>
    ref.watch(quoteRepositoryProvider).latestMetalRate(
          baseMetal: baseMetal,
          purity: purity,
        );
