/// `quotes`, `cost_lines`, `approval_gates`, `delivery_schedules`, `acceptance_criteria`.
///
/// The mockups had NO pricing engine: every money figure was hardcoded text, the commercial
/// screen had zero inputs, its four cost lines summed to $970 and no screen ever displayed that
/// total. D-003 replaces them with five customer-facing categories; D-004 makes every amount an
/// integer count of minor units plus a currency.
library;

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:dhanaos/domain/models/units.dart';
import 'package:dhanaos/domain/models/wire_enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'commercial.freezed.dart';
part 'commercial.g.dart';

/// One priced version of the job. Versions are kept, never overwritten — a customer who
/// approved v2 did not approve v3.
@freezed
abstract class Quote with _$Quote {
  const Quote._();

  const factory Quote({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @Default(1) int version,
    @QuoteStatusConverter() @Default(QuoteStatus.draft) QuoteStatus status,
    @PricingBasisConverter() @Default(PricingBasis.fixed) PricingBasis basis,

    /// Revealed by `costPlus`. The mockup's three basis buttons had no JavaScript at all, so
    /// neither the margin field nor the quote-approval state existed.
    @JsonKey(name: 'margin_pct') double? marginPct,
    @Default('INR') String currency,

    /// The "Locked Rate" badge implied a rate snapshot that no field stored a timestamp for.
    @JsonKey(name: 'metal_rate_id') String? metalRateId,
    @JsonKey(name: 'rate_locked_at') DateTime? rateLockedAt,

    /// From `commercial_requirements`' TARGET UNIT PRICE / MAX APPROVED, in minor units.
    @JsonKey(name: 'target_unit_price') int? targetUnitPriceMinor,
    @JsonKey(name: 'max_approved') int? maxApprovedMinor,

    /// Derived by `fn_recalc_quote`. Never computed in the client and written back — the server
    /// owns these so two devices cannot disagree about a total.
    @JsonKey(name: 'subtotal') @Default(0) int subtotalMinor,
    @JsonKey(name: 'tax_total') @Default(0) int taxTotalMinor,
    @JsonKey(name: 'grand_total') @Default(0) int grandTotalMinor,
    @JsonKey(name: 'valid_until') DateTime? validUntil,
    @JsonKey(name: 'sent_at') DateTime? sentAt,
    @JsonKey(name: 'decided_at') DateTime? decidedAt,
    @JsonKey(name: 'decided_by') String? decidedBy,

    /// D-006: `pricing_approval` offered only "Approve". Rejection and counter-offer needed a
    /// reason field, and a place to put the number.
    @JsonKey(name: 'decision_note') String? decisionNote,
    @JsonKey(name: 'counter_amount') int? counterAmountMinor,
    @JsonKey(name: 'created_at') required DateTime createdAt,

    /// Hydrated by a nested select. Not written back — cost lines are their own rows.
    @JsonKey(name: 'cost_lines', includeToJson: false)
    @Default(<CostLine>[])
    List<CostLine> lines,
  }) = _Quote;

  factory Quote.fromJson(Map<String, dynamic> json) => _$QuoteFromJson(json);

  Money get subtotal => Money(subtotalMinor, currency);
  Money get taxTotal => Money(taxTotalMinor, currency);
  Money get grandTotal => Money(grandTotalMinor, currency);

  Money? get targetUnitPrice =>
      targetUnitPriceMinor == null ? null : Money(targetUnitPriceMinor!, currency);

  Money? get maxApproved =>
      maxApprovedMinor == null ? null : Money(maxApprovedMinor!, currency);

  Money? get counterAmount =>
      counterAmountMinor == null ? null : Money(counterAmountMinor!, currency);

  /// The subtotal recomputed from the lines this quote carries, for reconciling against the
  /// server figure before sending a quote out.
  Money get lineSubtotal {
    var total = Money(0, currency);
    for (final line in lines) {
      if (line.isClientOwned) continue; // a client's own material is not a charge
      total += line.amountIn(currency);
    }
    return total;
  }

  bool get totalsAgree => lineSubtotal.minor == subtotalMinor;

  /// D-003: the five customer-facing categories, each with its own total. This is the breakdown
  /// a customer actually approves.
  Map<CostCategory, Money> get byCategory {
    final out = <CostCategory, Money>{};
    for (final c in CostCategory.values) {
      out[c] = Money(0, currency);
    }
    for (final line in lines) {
      if (line.isClientOwned) continue;
      out[line.category] = out[line.category]! + line.amountIn(currency);
    }
    return out;
  }

  /// 0.0 .. 1.0+ against the approved ceiling. The mockup's utilisation bar was literally
  /// `style="width: 85%"` when the real figure was 90.8%, so this is always computed.
  double? get utilization {
    final ceiling = maxApprovedMinor;
    if (ceiling == null || ceiling == 0) return null;
    return grandTotalMinor / ceiling;
  }

  /// '90.8%' — one decimal, because the gap between 85 and 90.8 is the whole point.
  String? get utilizationLabel {
    final u = utilization;
    return u == null ? null : '${(u * 100).toStringAsFixed(1)}%';
  }

  bool get isOverCeiling {
    final ceiling = maxApprovedMinor;
    return ceiling != null && grandTotalMinor > ceiling;
  }

  bool get isRateLocked => metalRateId != null && rateLockedAt != null;

  /// Cost Plus must reveal a margin field — a basis of `costPlus` with no margin is unfinished.
  bool get needsMargin => basis.needsMargin && marginPct == null;

  /// Quote basis introduces an approval state the mockups never had.
  bool get needsApproval => basis.needsApproval;

  bool get isExpired {
    final until = validUntil;
    if (until == null) return false;
    if (status == QuoteStatus.approved) return false;
    final today = DateTime.now();
    return DateTime(until.year, until.month, until.day)
        .isBefore(DateTime(today.year, today.month, today.day));
  }

  bool get isDecided => status != QuoteStatus.draft && status != QuoteStatus.sent;

  /// D-006: rejecting or counter-offering owes the customer's side a reason, the same asymmetry
  /// D-011 rule 2 applies to a CAD rejection.
  bool get decisionNeedsNote =>
      (status == QuoteStatus.rejected || status == QuoteStatus.counterOffered) &&
      (decisionNote?.trim().isEmpty ?? true);

  /// 'v2 · Approved · ₹4,85,000.00'
  String get displayLabel => 'v$version · ${status.label} · ${grandTotal.format()}';
}

/// `cost_lines` — one charge on a quote. D-003: every line rolls up into exactly one of the five
/// customer-facing categories.
@freezed
abstract class CostLine with _$CostLine {
  const CostLine._();

  const factory CostLine({
    required String id,
    @JsonKey(name: 'quote_id') required String quoteId,
    @CostCategoryConverter() required CostCategory category,

    /// 'Master Crafter - Assembly & Polish'.
    required String label,

    /// '18K White Gold (14.2g)'.
    String? detail,
    @JsonKey(name: 'supplied_by') @SuppliedByConverter() @Default(SuppliedBy.house)
    SuppliedBy suppliedBy,
    @Default(1.0) double qty,
    @UomOrNull() Uom? unit,

    /// Minor units. Paired with the quote's currency, never with a currency of its own — a
    /// quote in two currencies is not a quote.
    @JsonKey(name: 'unit_amount') @Default(0) int unitAmountMinor,
    @JsonKey(name: 'amount') @Default(0) int amountMinor,

    /// D-004: jewellery is HSN 7113. Required per line, because a certification service line
    /// is taxed at a different rate from the metal.
    @JsonKey(name: 'hsn_code') String? hsnCode,
    @JsonKey(name: 'tax_rate_pct') double? taxRatePct,

    /// When the client owns the material this is a declared value for insurance, not a charge.
    @JsonKey(name: 'is_client_owned') @Default(false) bool isClientOwned,
    @JsonKey(name: 'declared_value') int? declaredValueMinor,
    @Default(0) int position,
  }) = _CostLine;

  factory CostLine.fromJson(Map<String, dynamic> json) => _$CostLineFromJson(json);

  /// Pass `quote.currency`.
  Money unitAmountIn(String currency) => Money(unitAmountMinor, currency);

  Money amountIn(String currency) => Money(amountMinor, currency);

  Money? declaredValueIn(String currency) =>
      declaredValueMinor == null ? null : Money(declaredValueMinor!, currency);

  /// What `amount` should be. Kept as a check rather than as the source, because the stored
  /// value is what was quoted and agreed even if a rate later moves.
  Money computedAmount(String currency) => unitAmountIn(currency) * qty;

  bool amountAgrees(String currency) =>
      computedAmount(currency).minor == amountMinor;

  /// D-004: falls back to the statutory rate for the category rather than to zero. A missing
  /// rate that silently means "no tax" is how an invoice becomes illegal.
  double get effectiveTaxRatePct => taxRatePct ?? GstRates.forCategory(category.wire);

  String get effectiveHsnCode => hsnCode ?? '7113';

  /// The CGST/SGST/IGST split for this line.
  GstBreakdown gst({required String currency, required bool interstate}) => GstBreakdown.on(
        amountIn(currency),
        ratePct: effectiveTaxRatePct,
        interstate: interstate,
      );

  /// '14.2 g' / '1 pc' / '2' when no unit was chosen.
  String get qtyLabel {
    final n = trimDecimal(qty, maxDigits: 3);
    return unit == null ? n : '$n ${unit!.symbol}';
  }

  /// '18K White Gold (14.2g)' if a detail was written, else the quantity.
  String get detailLabel {
    final d = detail?.trim();
    return d == null || d.isEmpty ? qtyLabel : d;
  }
}

/// `approval_gates` — `review_job_order` showed three gates, all "Pending", with no screen
/// behind any of them.
@freezed
abstract class ApprovalGate with _$ApprovalGate {
  const ApprovalGate._();

  const factory ApprovalGate({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @ApprovalGateKindConverter() required ApprovalGateKind kind,
    @ApprovalGateStateConverter() @Default(ApprovalGateState.pending) ApprovalGateState state,
    @JsonKey(name: 'decided_by') String? decidedBy,
    @JsonKey(name: 'decided_at') DateTime? decidedAt,
    String? note,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _ApprovalGate;

  factory ApprovalGate.fromJson(Map<String, dynamic> json) => _$ApprovalGateFromJson(json);

  bool get isPending => state == ApprovalGateState.pending;
  bool get isApproved => state == ApprovalGateState.approved;
  bool get isRejected => state == ApprovalGateState.rejected;

  /// D-006: a rejected gate owes a reason, like every other rejection in the system.
  bool get needsNote => isRejected && (note?.trim().isEmpty ?? true);

  UserRole get decidingRole => kind.decidingRole;
}

/// `delivery_schedules` — the buffers between "done on the bench" and "in the customer's hand".
@freezed
abstract class DeliverySchedule with _$DeliverySchedule {
  const DeliverySchedule._();

  const factory DeliverySchedule({
    @JsonKey(name: 'job_id') required String jobId,
    @JsonKey(name: 'requested_date') DateTime? requestedDate,
    @JsonKey(name: 'hard_deadline') @Default(false) bool hardDeadline,
    @JsonKey(name: 'partial_allowed') @Default(true) bool partialAllowed,
    @PriorityConverter() @Default(Priority.standard) Priority priority,

    /// The mockup hardcoded both buffers as constants that never varied with priority, and its
    /// own source carried the comment "Could adjust buffers here based on priority".
    @JsonKey(name: 'dispatch_buffer_d') @Default(2) int dispatchBufferD,

    /// Must be zeroed when no lab was chosen — a declared cross-screen dependency nobody wired.
    @JsonKey(name: 'cert_buffer_d') @Default(3) int certBufferD,
    @JsonKey(name: 'recommended_done') DateTime? recommendedDone,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,
  }) = _DeliverySchedule;

  factory DeliverySchedule.fromJson(Map<String, dynamic> json) =>
      _$DeliveryScheduleFromJson(json);

  int get totalBufferDays => dispatchBufferD + certBufferD;

  /// Latest date the bench can finish and still hit the requested date.
  DateTime? get latestBenchCompletion {
    final requested = requestedDate;
    return requested?.subtract(Duration(days: totalBufferDays));
  }

  /// The stored recommendation if the server set one, else the derived date, so a screen always
  /// has a target to show.
  DateTime? get effectiveBenchTarget => recommendedDone ?? latestBenchCompletion;

  /// The buffer a priority earns. A rush job does not get a shorter courier, but it does get
  /// less slack in the plan.
  int recommendedDispatchBuffer() => switch (priority) {
        Priority.standard => 2,
        Priority.rush => 1,
        Priority.critical => 1,
      };

  /// The cross-screen dependency, stated as a check the UI can act on: choosing no lab must
  /// zero the certification buffer.
  bool certBufferAgreesWith(CertLab lab) => !lab.skipsStage || certBufferD == 0;

  /// 'Standard · 5 day buffer'.
  String get bufferLabel => '${priority.label} · $totalBufferDays day buffer';
}

/// `acceptance_criteria` — what the piece is measured against at QC, agreed up front.
@freezed
abstract class AcceptanceCriteria with _$AcceptanceCriteria {
  const AcceptanceCriteria._();

  const factory AcceptanceCriteria({
    @JsonKey(name: 'job_id') required String jobId,
    @JsonKey(name: 'match_cad') @Default(true) bool matchCad,
    @JsonKey(name: 'high_polish') @Default(true) bool highPolish,
    @JsonKey(name: 'size_weight_conform') @Default(true) bool sizeWeightConform,

    /// Opt-in in the mockup, where the actual figure was baked into a label.
    @JsonKey(name: 'strict_tolerance') @Default(false) bool strictTolerance,
    @JsonKey(name: 'tolerance_mm') double? toleranceMm,
    @JsonKey(name: 'stones_secure') @Default(true) bool stonesSecure,
    @Default(true) bool symmetry,
    @JsonKey(name: 'cert_lab') @CertLabConverter() @Default(CertLab.igi) CertLab certLab,

    /// 'Other' had no name field in the mockup, so "Other" was all anyone ever knew.
    @JsonKey(name: 'cert_lab_other') String? certLabOther,
    @JsonKey(name: 'authority') @QualityAuthorityConverter() @Default(QualityAuthority.jeweler)
    QualityAuthority authority,
    @JsonKey(name: 'customer_notes') String? customerNotes,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,
  }) = _AcceptanceCriteria;

  factory AcceptanceCriteria.fromJson(Map<String, dynamic> json) =>
      _$AcceptanceCriteriaFromJson(json);

  /// 'IGI' / 'HRD Antwerp' / the typed name behind 'Other'.
  String get certLabLabel {
    if (certLab == CertLab.other) {
      final named = certLabOther?.trim();
      return named == null || named.isEmpty ? 'Other' : named;
    }
    return certLab.label;
  }

  /// Choosing no lab must skip the certification stage and zero the delivery buffer.
  bool get skipsCertification => certLab.skipsStage;

  /// Selecting `customer` must insert a portal approval gate before QC sign-off. The mockups
  /// offered the option and had no such transition or screen.
  bool get needsCustomerGate => authority.needsCustomerGate;

  /// 'Other' selected with no name typed is an unfinished answer.
  bool get certLabNeedsName =>
      certLab == CertLab.other && (certLabOther?.trim().isEmpty ?? true);

  /// The dimensional tolerance QC works to. Strict mode uses the agreed figure; otherwise the
  /// shop default of 0.05 mm applies.
  double get effectiveToleranceMm => strictTolerance ? (toleranceMm ?? 0.05) : 0.05;

  /// The checklist this job's QC inspection is seeded from, in the order an inspector works.
  /// Hallmarking is kept from the rejected mobile tracker (D-002) because it is a real Indian
  /// market requirement.
  List<String> get checklistLabels => [
        if (matchCad) 'Matches approved CAD',
        if (sizeWeightConform) 'Metal weight and size verified',
        if (stonesSecure) 'All stones secure',
        if (symmetry) 'Symmetry verified',
        if (highPolish) 'Finish and polish to standard',
        if (!skipsCertification) 'Certificate received and matches piece',
        'Hallmark applied',
      ];

  /// 'Matches CAD · ±0.05 mm · IGI · Jeweler'
  String get summary =>
      '${checklistLabels.length} checks · ± ${mmLabel(effectiveToleranceMm)} · '
      '$certLabLabel · ${authority.label}';
}
