/// `invoices`, `payments`, `metal_rates` — D-004.
///
/// Entirely absent from the mockups: "Confirm Dispatch" was the last wired action in all 46
/// screens, and every money figure was a hardcoded USD string. An Indian manufacturer cannot
/// legally ship without a tax invoice, so the invoice is a first-class document here rather than
/// a PDF export bolted on later.
library;

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:dhanaos/domain/models/units.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'billing.freezed.dart';
part 'billing.g.dart';

/// A GST tax invoice. The CGST/SGST/IGST split is stored, not derived at render time, because an
/// issued invoice must read the same next year even if a rate changes.
@freezed
abstract class Invoice with _$Invoice {
  const Invoice._();

  const factory Invoice({
    required String id,
    @JsonKey(name: 'org_id') required String orgId,
    @JsonKey(name: 'job_id') String? jobId,
    @JsonKey(name: 'customer_id') required String customerId,
    @JsonKey(name: 'invoice_no') required String invoiceNo,
    @JsonKey(name: 'invoice_date') required DateTime invoiceDate,
    @Default('INR') String currency,

    /// The customer's state. With the org's own state it decides the tax split.
    @JsonKey(name: 'place_of_supply') String? placeOfSupply,

    /// Drives IGST versus CGST + SGST.
    @JsonKey(name: 'is_interstate') @Default(false) bool isInterstate,

    /// All minor units.
    @JsonKey(name: 'subtotal') @Default(0) int subtotalMinor,
    @JsonKey(name: 'cgst') @Default(0) int cgstMinor,
    @JsonKey(name: 'sgst') @Default(0) int sgstMinor,
    @JsonKey(name: 'igst') @Default(0) int igstMinor,
    @JsonKey(name: 'grand_total') @Default(0) int grandTotalMinor,
    @JsonKey(name: 'pdf_attachment') String? pdfAttachment,

    /// Once issued, an invoice is immutable in practice — a correction is a credit note, not an
    /// edit.
    @JsonKey(name: 'issued_at') DateTime? issuedAt,
    @JsonKey(name: 'created_at') required DateTime createdAt,

    /// Hydrated by a nested select. Not written back — payments are their own rows.
    @JsonKey(name: 'payments', includeToJson: false)
    @Default(<Payment>[])
    List<Payment> payments,
  }) = _Invoice;

  factory Invoice.fromJson(Map<String, dynamic> json) => _$InvoiceFromJson(json);

  Money get subtotal => Money(subtotalMinor, currency);
  Money get cgst => Money(cgstMinor, currency);
  Money get sgst => Money(sgstMinor, currency);
  Money get igst => Money(igstMinor, currency);
  Money get grandTotal => Money(grandTotalMinor, currency);

  /// The stored split, in the shape `core/money.dart` works with.
  GstBreakdown get gst => GstBreakdown(
        taxable: subtotal,
        cgst: cgst,
        sgst: sgst,
        igst: igst,
      );

  Money get tax => gst.tax;

  /// An invoice whose parts do not add up cannot be issued. Cheap to check, expensive to miss.
  bool get totalsBalance => (subtotal + tax).minor == grandTotalMinor;

  /// An interstate invoice carrying CGST, or an intrastate one carrying IGST, is the wrong
  /// document — a real filing error, not a cosmetic one.
  bool get splitMatchesSupply =>
      isInterstate ? (cgstMinor == 0 && sgstMinor == 0) : igstMinor == 0;

  bool get isIssued => issuedAt != null;
  bool get isDraft => issuedAt == null;

  Money get amountPaid {
    var total = Money(0, currency);
    for (final p in payments) {
      if (p.currency != currency) continue; // a cross-currency receipt is reconciled, not summed
      total += p.amount;
    }
    return total;
  }

  Money get amountDue {
    final due = grandTotal - amountPaid;
    return due.isNegative ? Money(0, currency) : due;
  }

  bool get isPaid => amountPaid.minor >= grandTotalMinor && grandTotalMinor > 0;

  bool get isPartlyPaid => amountPaid.minor > 0 && !isPaid;

  /// 'DH/2026/0184 · ₹4,99,550.00'.
  String get displayLabel => '$invoiceNo · ${grandTotal.format()}';
}

/// `payments` — money actually received against an invoice.
@freezed
abstract class Payment with _$Payment {
  const Payment._();

  const factory Payment({
    required String id,
    @JsonKey(name: 'invoice_id') required String invoiceId,

    /// Minor units.
    @JsonKey(name: 'amount') required int amountMinor,
    @Default('INR') String currency,

    /// 'neft', 'upi', 'cheque'.
    String? method,

    /// UTR / cheque number — what reconciliation is done against.
    String? reference,
    @JsonKey(name: 'received_at') required DateTime receivedAt,
    @JsonKey(name: 'recorded_by') String? recordedBy,
  }) = _Payment;

  factory Payment.fromJson(Map<String, dynamic> json) => _$PaymentFromJson(json);

  Money get amount => Money(amountMinor, currency);

  /// A receipt with no reference cannot be matched to a bank statement.
  bool get isReconcilable => reference?.trim().isNotEmpty ?? false;

  /// 'UPI · ₹1,00,000.00'.
  String get displayLabel {
    final m = method?.trim();
    final label = m == null || m.isEmpty ? 'Payment' : m.toUpperCase();
    return '$label · ${amount.format()}';
  }
}

/// `metal_rates` — the rate snapshot behind `commercial_requirements`' "Locked Rate" badge,
/// which implied a snapshot that no field stored a timestamp for.
@freezed
abstract class MetalRate with _$MetalRate {
  const MetalRate._();

  const factory MetalRate({
    required String id,
    @JsonKey(name: 'org_id') required String orgId,
    @JsonKey(name: 'base_metal') @BaseMetalConverter() required BaseMetal baseMetal,

    /// Null means the rate applies to the metal at any purity — a fine-gold rate that the
    /// quote scales itself.
    @MetalPurityOrNull() MetalPurity? purity,
    @Default('INR') String currency,

    /// Minor units per gram.
    @JsonKey(name: 'rate_per_g') required int ratePerGMinor,

    /// 'MCX', 'manual'.
    String? source,
    @JsonKey(name: 'effective_at') required DateTime effectiveAt,
    @JsonKey(name: 'created_by') String? createdBy,
  }) = _MetalRate;

  factory MetalRate.fromJson(Map<String, dynamic> json) => _$MetalRateFromJson(json);

  Money get ratePerG => Money(ratePerGMinor, currency);

  /// What a weight costs at this rate. Rounds once, at the end, because rounding per gram and
  /// then multiplying is how a quote drifts from an invoice.
  Money costFor(double grams) => ratePerG * grams;

  /// '₹6,842.00 / g · 18K · MCX'.
  String get displayLabel {
    final parts = <String>[
      '${ratePerG.format()} / g',
      if (purity != null) purity!.label,
      if (source?.trim().isNotEmpty ?? false) source!.trim(),
    ];
    return parts.join(' · ');
  }

  /// A rate is a snapshot, so a quote that locked it must show how old it is.
  Duration get age => DateTime.now().toUtc().difference(effectiveAt.toUtc());

  /// Metal moves daily. A rate older than this should not be silently reused in a new quote.
  bool get isStale => age.inHours >= 24;

  /// '14.2 g at ₹6,842.00 / g'.
  String quotationLine(double grams) =>
      '${gramLabel(grams)} at ${ratePerG.format()} / g';
}
