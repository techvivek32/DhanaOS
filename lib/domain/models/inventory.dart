/// `inventory_items`, `stock_allocations`, `stock_transactions`, `goods_in_receipts`.
///
/// `inventory_management` shipped NO JavaScript at all: search, filter and "Assign" did nothing
/// and both stock bars were hardcoded widths. Two distinct stock models coexisted in that one
/// screen — metals bulk by gram, stones serialised with species-dependent attributes — and they
/// are modelled separately here.
library;

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:dhanaos/domain/models/units.dart';
import 'package:dhanaos/domain/models/wire_enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'inventory.freezed.dart';
part 'inventory.g.dart';

@freezed
class InventoryItem with _$InventoryItem {
  const InventoryItem._();

  const factory InventoryItem({
    required String id,
    @JsonKey(name: 'org_id') required String orgId,
    @StockKindConverter() required StockKind kind,

    /// 'AU-750', 'PT-950', 'DIA-9982-A'.
    required String code,

    /// '18K Gold', 'Round Brilliant Diamond'.
    required String label,
    @UomConverter() @Default(Uom.gram) Uom uom,

    /// `metalBulk`: a running balance in grams. `stoneSerialized`: always 0 or 1, because the
    /// item IS the stone.
    @JsonKey(name: 'qty_on_hand') @Default(0.0) double qtyOnHand,
    @JsonKey(name: 'qty_allocated') @Default(0.0) double qtyAllocated,

    /// The progress bars in the mockup implied a threshold that no field stored.
    @JsonKey(name: 'reorder_level') double? reorderLevel,

    /// Bulk metal attributes.
    @JsonKey(name: 'base_metal') @BaseMetalOrNull() BaseMetal? baseMetal,
    @MetalPurityOrNull() MetalPurity? purity,

    /// Serialised stone attributes. The mockup proved these must be species-typed, not a fixed
    /// 4C table: its diamond row showed CARAT/COLOR/CLARITY while its ruby row showed
    /// CARAT/CUT/ORIGIN. Common columns here, species extras in [attrs].
    @JsonKey(name: 'stone_type') @StoneTypeOrNull() StoneType? stoneType,
    @JsonKey(name: 'stone_origin') @StoneOriginOrNull() StoneOrigin? stoneOrigin,
    @StoneShapeOrNull() StoneShape? shape,
    double? carat,

    /// {"color":"F","clarity":"VVS2"} for a diamond,
    /// {"cut":"EX","treatment":"Unheated"} for a ruby.
    @Default(<String, dynamic>{}) Map<String, dynamic> attrs,
    @JsonKey(name: 'cert_lab') @CertLabOrNull() CertLab? certLab,
    @JsonKey(name: 'cert_number') String? certNumber,
    @JsonKey(name: 'cert_pdf_id') String? certPdfId,

    /// Costing, absent entirely from the mockup. Minor units per [uom].
    @JsonKey(name: 'unit_cost') int? unitCostMinor,
    @Default('INR') String currency,
    @JsonKey(name: 'supplier_id') String? supplierId,
    @JsonKey(name: 'lot_ref') String? lotRef,

    /// 'Vault A, Tray 4'.
    String? location,
    @JsonKey(name: 'photo_id') String? photoId,
    @JsonKey(name: 'is_active') @Default(true) bool isActive,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _InventoryItem;

  factory InventoryItem.fromJson(Map<String, dynamic> json) => _$InventoryItemFromJson(json);

  /// What can still be committed to a job. `v_inventory_available` computes the same figure in
  /// SQL for server-side filtering; this keeps a local list honest without a round trip.
  double get qtyAvailable => qtyOnHand - qtyAllocated;

  /// The threshold behind the mockup's hardcoded progress bar.
  bool get needsReorder {
    final level = reorderLevel;
    return level != null && qtyOnHand <= level;
  }

  /// 0.0 .. 1.0 against the reorder level, for the stock bar. Null when no threshold is set —
  /// better an absent bar than a fictional one.
  double? get stockRatio {
    final level = reorderLevel;
    if (level == null || level <= 0) return null;
    return (qtyOnHand / level).clamp(0.0, 1.0);
  }

  bool get isSerialized => kind == StockKind.stoneSerialized;
  bool get isBulkMetal => kind == StockKind.metalBulk;

  /// A serialised stone is either in the vault or it is not — there is no partial diamond.
  bool get isInStock => qtyAvailable > 0;

  Money? get unitCost => unitCostMinor == null ? null : Money(unitCostMinor!, currency);

  /// Value of a quantity at the recorded unit cost.
  Money? valueOf(double qty) {
    final cost = unitCost;
    return cost == null ? null : cost * qty;
  }

  Money? get onHandValue => valueOf(qtyOnHand);

  /// A species-typed attribute: `item.attr('clarity')`.
  String? attr(String key) {
    final v = attrs[key];
    return v == null ? null : v.toString();
  }

  /// '124.5 g' / '1 pc' / '1.25 ct'.
  String get quantityLabel => '${trimDecimal(qtyOnHand, maxDigits: 3)} ${uom.symbol}';

  String get availableLabel => '${trimDecimal(qtyAvailable, maxDigits: 3)} ${uom.symbol}';

  /// Species-typed summary. A diamond reads CARAT · COLOR · CLARITY; a ruby reads
  /// CARAT · CUT · ORIGIN — which is exactly why `attrs` is not a fixed 4C table.
  String get gradeSummary {
    if (isBulkMetal) {
      final parts = <String>[
        if (purity != null) purity!.label,
        if (baseMetal != null) baseMetal!.label,
      ];
      return parts.isEmpty ? label : parts.join(' ');
    }
    final parts = <String>[
      if (carat != null) caratLabel(carat),
      if (shape != null) shape!.label,
      // Never dropped: natural and lab-grown are different goods at different prices.
      if (stoneOrigin != null) stoneOrigin!.label,
    ];
    final graded = stoneType?.usesFourCs ?? false;
    if (graded) {
      final color = attr('color');
      final clarity = attr('clarity');
      if (color != null) parts.add(color);
      if (clarity != null) parts.add(clarity);
    } else {
      final cut = attr('cut');
      final treatment = attr('treatment');
      if (cut != null) parts.add(cut);
      if (treatment != null) parts.add(treatment);
    }
    return parts.isEmpty ? label : parts.join(' · ');
  }

  /// 'AU-750 · 18K Gold'.
  String get displayLabel => '$code · $label';
}

/// `stock_allocations` — the job picker the single "Assign" button in the mockup implied and did
/// not have.
@freezed
class StockAllocation with _$StockAllocation {
  const StockAllocation._();

  const factory StockAllocation({
    required String id,
    @JsonKey(name: 'item_id') required String itemId,
    @JsonKey(name: 'job_id') required String jobId,

    /// Set when the allocation satisfies a specific stone line on the job.
    @JsonKey(name: 'stone_id') String? stoneId,
    required double qty,
    @JsonKey(name: 'allocated_by') String? allocatedBy,
    @JsonKey(name: 'allocated_at') required DateTime allocatedAt,
    @JsonKey(name: 'released_at') DateTime? releasedAt,

    /// When it was physically pulled from the vault. Reserved and issued are different states —
    /// a reserved stone is still on the shelf.
    @JsonKey(name: 'issued_at') DateTime? issuedAt,
  }) = _StockAllocation;

  factory StockAllocation.fromJson(Map<String, dynamic> json) =>
      _$StockAllocationFromJson(json);

  bool get isOpen => releasedAt == null;
  bool get isIssued => issuedAt != null;

  /// Reserved but never pulled, so it is still holding stock a different job could use.
  bool get isReservedOnly => isOpen && issuedAt == null;
}

/// `stock_transactions` — append-only movements. UPDATE and DELETE are revoked in Postgres.
///
/// The mockup's own dashboard alerted "Stones missing for DH-1061 — Melee diamonds count
/// mismatch at receiving" while offering nothing that could record a movement. Reconciliation is
/// a live business problem the designs never solved.
@freezed
class StockTransaction with _$StockTransaction {
  const StockTransaction._();

  const factory StockTransaction({
    required String id,
    @JsonKey(name: 'org_id') required String orgId,
    @JsonKey(name: 'item_id') required String itemId,
    @StockTxnKindConverter() required StockTxnKind kind,

    /// Signed: receive positive, issue and scrap negative.
    required double qty,
    @JsonKey(name: 'job_id') String? jobId,
    @LifecycleStageOrNull() LifecycleStage? stage,
    @JsonKey(name: 'unit_cost') int? unitCostMinor,
    @Default('INR') String currency,
    @JsonKey(name: 'supplier_id') String? supplierId,
    @JsonKey(name: 'lot_ref') String? lotRef,

    /// Invoice or GRN number.
    String? reference,
    String? note,
    @JsonKey(name: 'created_by') String? createdBy,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _StockTransaction;

  factory StockTransaction.fromJson(Map<String, dynamic> json) =>
      _$StockTransactionFromJson(json);

  Money? get unitCost => unitCostMinor == null ? null : Money(unitCostMinor!, currency);

  /// Absolute value of the movement, for a ledger column that shows magnitude not direction.
  Money? get value {
    final cost = unitCost;
    return cost == null ? null : cost * qty.abs();
  }

  bool get isInbound => qty > 0;
  bool get isOutbound => qty < 0;

  /// Metal lost to filings, polishing and sprues — the line that has to reconcile at month end.
  bool get isLoss => kind == StockTxnKind.scrap;

  /// The sign the quantity should carry for this movement kind. `adjust` may be either way, so
  /// it reports 0 and this check passes.
  bool get signAgreesWithKind {
    final expected = kind.sign;
    if (expected == 0) return true;
    return qty.sign == expected;
  }

  /// '+124.5 g' / '-0.8 g' — signed, because direction is the point of a ledger row.
  String qtyLabel(Uom uom) {
    final sign = qty > 0 ? '+' : '';
    return '$sign${trimDecimal(qty, maxDigits: 3)} ${uom.symbol}';
  }
}

/// `goods_in_receipts` — the custody record for a client's own materials.
///
/// The critical gap in the mockups: "Verified & Logged in Inventory" was a status chip with no
/// declared value, no verifier identity, no timestamp, no receipt id and no risk
/// acknowledgement behind it. The shop took custody of a client's diamond with no record of what
/// it had accepted.
@freezed
class GoodsInReceipt with _$GoodsInReceipt {
  const GoodsInReceipt._();

  const factory GoodsInReceipt({
    required String id,
    @JsonKey(name: 'org_id') required String orgId,
    @JsonKey(name: 'job_id') required String jobId,
    @JsonKey(name: 'customer_id') String? customerId,

    /// 'GRN-2026-00184'.
    @JsonKey(name: 'receipt_code') required String receiptCode,

    /// What was handed over, in the client's words as well as ours.
    required String description,

    /// Minor units. NOT NULL in the schema — a custody record without a value is the exact
    /// failure this table exists to prevent.
    @JsonKey(name: 'declared_value') required int declaredValueMinor,
    @Default('INR') String currency,

    /// NOT NULL: a named person accepted the goods.
    @JsonKey(name: 'received_by') required String receivedBy,
    @JsonKey(name: 'received_at') required DateTime receivedAt,
    @JsonKey(name: 'customer_sig_id') String? customerSigId,

    /// Attachment ids of the condition photographs taken at hand-over.
    @JsonKey(name: 'photo_ids') @Default(<String>[]) List<String> photoIds,
    @JsonKey(name: 'cert_id') String? certId,
    @JsonKey(name: 'risk_ack') @Default(false) bool riskAck,
    @JsonKey(name: 'insurance_ref') String? insuranceRef,

    /// Set when the goods went back to the client, finished or not.
    @JsonKey(name: 'returned_at') DateTime? returnedAt,
    String? note,
  }) = _GoodsInReceipt;

  factory GoodsInReceipt.fromJson(Map<String, dynamic> json) =>
      _$GoodsInReceiptFromJson(json);

  Money get declaredValue => Money(declaredValueMinor, currency);

  /// The goods are still in the building and still the shop's responsibility.
  bool get isInCustody => returnedAt == null;

  /// Evidence a claim would need: a signature, photographs and an accepted risk statement.
  bool get isFullyDocumented =>
      declaredValueMinor > 0 && riskAck && photoIds.isNotEmpty && customerSigId != null;

  /// What is still missing from the record, so the screen names the gap.
  List<String> get missingEvidence => [
        if (declaredValueMinor <= 0) 'Declared value',
        if (!riskAck) 'Risk acknowledgement',
        if (photoIds.isEmpty) 'Condition photographs',
        if (customerSigId == null) 'Customer signature',
        if (insuranceRef == null) 'Insurance reference',
      ];

  /// How long the shop has held the goods.
  Duration get custodyDuration =>
      (returnedAt ?? DateTime.now()).toUtc().difference(receivedAt.toUtc());

  /// 'GRN-2026-00184 · ₹12,50,000.00'.
  String get displayLabel => '$receiptCode · ${declaredValue.format()}';
}
