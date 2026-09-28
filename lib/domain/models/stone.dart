/// `stones` and `melee_parcels` — the worst version drift in the corpus: 7 variants of the
/// stone requirements screen, none complete, each redesign making a different subset editable.
/// These models are the union of all of them (D-012).
///
/// Two fields exist here that must never be quietly dropped again:
///   * [Stone.origin] — Natural vs Lab Grown, which survived in exactly 1 of 46 mockups.
///   * the custody block — declared value, verifier, timestamp, receipt code and risk
///     acknowledgement, required whenever the client supplies the stone.
library;

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:dhanaos/domain/models/units.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'stone.freezed.dart';
part 'stone.g.dart';

@freezed
abstract class Stone with _$Stone {
  const Stone._();

  const factory Stone({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @StoneRoleConverter() @Default(StoneRole.center) StoneRole role,

    /// Ordering within a role, so "Side Stone 2" is stable across sessions.
    @Default(0) int position,
    @StoneSourcingConverter() @Default(StoneSourcing.needsSourcing) StoneSourcing sourcing,
    @JsonKey(name: 'stone_type') @StoneTypeOrNull() StoneType? stoneType,

    /// D-012, the field to watch. Natural vs lab-grown changes valuation, disclosure
    /// obligations and certification. It survived in exactly one file out of 46 and every
    /// later redesign silently dropped it — so it is never hidden, never defaulted.
    @StoneOriginOrNull() StoneOrigin? origin,
    @StoneShapeOrNull() StoneShape? shape,

    /// Typed carat input, lost in the later variants which offered only preset chips.
    double? carat,

    /// `refined_inputs` split the vague 'Dimensions (L x W x D mm)' text field into three
    /// discrete numbers. Kept discrete; joined only for display.
    @JsonKey(name: 'length_mm') double? lengthMm,
    @JsonKey(name: 'width_mm') double? widthMm,
    @JsonKey(name: 'depth_mm') double? depthMm,

    /// A grade, or a range when the customer will accept a band. Both were in the mockups —
    /// `interactive_inputs` had the ladder, another variant had 'F-G' as free text.
    @DiamondColorOrNull() DiamondColor? color,
    @JsonKey(name: 'color_range') String? colorRange,
    @DiamondClarityOrNull() DiamondClarity? clarity,
    @JsonKey(name: 'clarity_range') String? clarityRange,
    @DiamondCutOrNull() DiamondCut? cut,

    /// 'Unheated' — a coloured-stone attribute, not a 4C.
    String? treatment,

    /// 'MMR' (Myanmar).
    String? provenance,

    /// The user's own reference crop specified certification as a boolean toggle, not a lab
    /// dropdown — so the toggle and the lab are separate fields.
    @JsonKey(name: 'cert_required') @Default(false) bool certRequired,
    @JsonKey(name: 'cert_lab') @CertLabOrNull() CertLab? certLab,
    @JsonKey(name: 'cert_number') String? certNumber,
    @JsonKey(name: 'cert_attachment') String? certAttachment,
    @JsonKey(name: 'photo_attachment') String? photoAttachment,

    /// Goods-in custody, minor units. `stones` carries no currency column — the job's currency
    /// governs, so this is surfaced through [declaredValue].
    @JsonKey(name: 'declared_value') int? declaredValueMinor,
    @JsonKey(name: 'verified_by') String? verifiedBy,
    @JsonKey(name: 'verified_at') DateTime? verifiedAt,
    @JsonKey(name: 'receipt_code') String? receiptCode,
    @JsonKey(name: 'risk_ack') @Default(false) bool riskAck,

    /// Set when the stone was allocated from the vault rather than sourced or supplied.
    @JsonKey(name: 'inventory_item_id') String? inventoryItemId,
    String? notes,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _Stone;

  factory Stone.fromJson(Map<String, dynamic> json) => _$StoneFromJson(json);

  /// Pass `job.currency`. D-004: never a double, never a raw int in the UI.
  Money? declaredValue(String currency) =>
      declaredValueMinor == null ? null : Money(declaredValueMinor!, currency);

  // -------------------------------------------------------------- custody

  /// True when this stone belongs to the client and the shop is therefore holding it.
  bool get isCustomerSupplied => sourcing.requiresCustodyRecord;

  /// Every field a custody record needs. The mockups had a "Verified & Logged in Inventory"
  /// status chip and captured NONE of these: the shop took a client's diamond with no declared
  /// value, no verifier, no timestamp, no receipt and no risk acknowledgement. That is legal
  /// and insurance exposure, so the record is complete or the stone is not accepted.
  bool get hasCustodyRecord =>
      (declaredValueMinor ?? 0) > 0 &&
      verifiedBy != null &&
      verifiedAt != null &&
      (receiptCode?.trim().isNotEmpty ?? false) &&
      riskAck;

  /// The gate: a client-supplied stone with an incomplete record blocks the step.
  bool get needsCustodyRecord => isCustomerSupplied && !hasCustodyRecord;

  /// What is still missing, so the screen names the gap instead of just refusing.
  List<String> get missingCustodyFields {
    if (!isCustomerSupplied) return const [];
    return [
      if ((declaredValueMinor ?? 0) <= 0) 'Declared value',
      if (verifiedBy == null) 'Verified by',
      if (verifiedAt == null) 'Verified at',
      if (receiptCode?.trim().isNotEmpty != true) 'Receipt code',
      if (!riskAck) 'Risk acknowledgement',
    ];
  }

  // -------------------------------------------------------------- grading

  /// Diamond and moissanite are graded on the 4Cs; coloured stones are not, which is why the
  /// mockups' fixed 4C table was wrong for a ruby.
  bool get usesFourCs => stoneType?.usesFourCs ?? false;

  /// The grade or the accepted range, whichever was recorded. A range is a real answer — the
  /// customer said 'F-G' and meant it.
  String get colorLabel => color?.label ?? _text(colorRange);

  String get clarityLabel => clarity?.label ?? _text(clarityRange);

  String get cutLabel => cut?.label ?? '—';

  String get caratText => caratLabel(carat);

  /// '6.50 × 6.45 × 4.02 mm'.
  String get dimensionsText => dimensionsLabel(lengthMm, widthMm, depthMm);

  /// '1.25 ct · Round Brilliant · Natural · F · VS1' for a diamond;
  /// '1.25 ct · Oval · Natural · Unheated · MMR' for a ruby. Species-typed, not a fixed table.
  String get gradeSummary {
    final parts = <String>[
      if (carat != null) caratText,
      if (shape != null) shape!.label,
      // Origin is always shown when known — it is the field every redesign dropped.
      if (origin != null) origin!.label,
      if (usesFourCs) ...[
        if (color != null || colorRange != null) colorLabel,
        if (clarity != null || clarityRange != null) clarityLabel,
        if (cut != null) cut!.label,
      ] else ...[
        if (treatment?.trim().isNotEmpty ?? false) treatment!.trim(),
        if (provenance?.trim().isNotEmpty ?? false) provenance!.trim(),
      ],
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  /// 'Centre Stone · Diamond'.
  String get displayTitle {
    final type = stoneType?.label;
    return type == null ? role.label : '${role.label} · $type';
  }

  /// A certificate was asked for but no number has come back yet.
  bool get awaitingCertificate =>
      certRequired && (certNumber?.trim().isEmpty ?? true) && certAttachment == null;

  /// The stone still has to be found: not in the vault, not with the client.
  bool get needsProcurement =>
      sourcing == StoneSourcing.needsSourcing && inventoryItemId == null;

  /// Allocated from stock but the allocation row is missing — the "Assign" button in
  /// `inventory_management` implied a job picker that did not exist.
  bool get awaitingAllocation =>
      sourcing == StoneSourcing.inStock && inventoryItemId == null;

  /// Everything the wizard still needs before this stone is a buildable specification.
  List<String> get openQuestions => [
        if (stoneType == null) 'Stone type',
        // Never inferred from a default: valuation and disclosure hang on it.
        if (origin == null) 'Origin (Natural / Lab Grown)',
        if (shape == null) 'Shape',
        if (carat == null && lengthMm == null) 'Carat or dimensions',
        if (certRequired && certLab == null) 'Certifying lab',
        ...missingCustodyFields,
      ];
}

/// `melee_parcels` — small stones bought by the parcel, not individually specified.
///
/// D-012: the mockups' segmented control meant two different things across variants, timing
/// ("Include Now / Include Later") versus sourcing. Resolved to sourcing.
@freezed
abstract class MeleeParcel with _$MeleeParcel {
  const MeleeParcel._();

  const factory MeleeParcel({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @StoneSourcingConverter() @Default(StoneSourcing.needsSourcing) StoneSourcing sourcing,
    @JsonKey(name: 'stone_type') @StoneTypeConverter() @Default(StoneType.diamond) StoneType stoneType,

    /// Lab-grown melee is a different price and a different disclosure from natural melee.
    @StoneOriginOrNull() StoneOrigin? origin,
    @StoneShapeConverter() @Default(StoneShape.roundBrilliant) StoneShape shape,

    /// '1.2mm' to '1.5mm' — a parcel is specified by a size band, not one measurement.
    @JsonKey(name: 'size_min_mm') double? sizeMinMm,
    @JsonKey(name: 'size_max_mm') double? sizeMaxMm,

    /// Total carat weight across the parcel.
    @JsonKey(name: 'total_ctw') double? totalCtw,
    @JsonKey(name: 'piece_count') int? pieceCount,
    @JsonKey(name: 'color_range') String? colorRange,
    @JsonKey(name: 'clarity_range') String? clarityRange,
    String? notes,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _MeleeParcel;

  factory MeleeParcel.fromJson(Map<String, dynamic> json) => _$MeleeParcelFromJson(json);

  /// '1.2–1.5 mm'.
  String get sizeLabel => mmRangeLabel(sizeMinMm, sizeMaxMm);

  /// '0.45 ct tw'. The mockup's CAD note read "0.45ct tw (from 0.3ct)" — this is that figure.
  String get ctwLabel => totalCtw == null ? '—' : '${trimDecimal(totalCtw!)} ct tw';

  /// '42 pcs · 1.2–1.5 mm · 0.45 ct tw'.
  String get summary {
    final parts = <String>[
      if (pieceCount != null) '$pieceCount pcs',
      if (sizeMinMm != null || sizeMaxMm != null) sizeLabel,
      if (totalCtw != null) ctwLabel,
      if (origin != null) origin!.label,
    ];
    return parts.isEmpty ? shape.label : parts.join(' · ');
  }

  /// Average weight per stone, which is how a parcel is checked in at receiving. The mockups'
  /// own dashboard alerted "Melee diamonds count mismatch at receiving" with nothing behind it.
  double? get avgCaratPerPiece {
    final ctw = totalCtw;
    final n = pieceCount;
    if (ctw == null || n == null || n <= 0) return null;
    return ctw / n;
  }

  bool get needsProcurement => sourcing == StoneSourcing.needsSourcing;
}

String _text(String? value) {
  final v = value?.trim();
  return v == null || v.isEmpty ? '—' : v;
}
