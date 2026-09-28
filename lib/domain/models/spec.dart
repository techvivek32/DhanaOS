/// `product_specs`, `metal_specs`, `requirements`, `job_references` — what the intake wizard
/// captures.
///
/// D-012: these tables are the UNION of competing mockup variants. `metal_specs` in particular
/// merges `metal_materials` and `quick_specs`, which were never iterations of each other — they
/// were two screens for one step with disjoint field sets.
library;

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:dhanaos/domain/models/units.dart';
import 'package:dhanaos/domain/models/wire_enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'spec.freezed.dart';
part 'spec.g.dart';

/// The design specification. One row per job, keyed by `job_id`.
@freezed
abstract class ProductSpec with _$ProductSpec {
  const ProductSpec._();

  const factory ProductSpec({
    @JsonKey(name: 'job_id') required String jobId,
    @JsonKey(name: 'setting_style') @SettingStyleOrNull() SettingStyle? settingStyle,

    /// '6-Prong Cathedral', 'Micro-pave'. Required when the style is `other` — every "Other" in
    /// the mockups was preselected and had no follow-up field.
    @JsonKey(name: 'setting_detail') String? settingDetail,
    @JsonKey(name: 'metal_finish') @MetalFinishOrNull() MetalFinish? metalFinish,
    @JsonKey(name: 'band_profile') @BandProfileOrNull() BandProfile? bandProfile,
    @FitProfileOrNull() FitProfile? fit,
    @JsonKey(name: 'side_stones') @SideStoneSettingOrNull() SideStoneSetting? sideStones,
    @JsonKey(name: 'design_intent') @DesignIntentOrNull() DesignIntent? designIntent,

    /// The free text behind 'Other Idea', which the mockup preselected and then never asked for.
    @JsonKey(name: 'design_intent_note') String? designIntentNote,

    /// D-012: India sizing is primary for this market; US and UK are stored for conversion
    /// display, because the mockups disagreed about which scale they were showing.
    @JsonKey(name: 'ring_size_in') double? ringSizeIn,
    @JsonKey(name: 'ring_size_us') double? ringSizeUs,
    @JsonKey(name: 'ring_size_uk') String? ringSizeUk,
    @JsonKey(name: 'band_width_mm') double? bandWidthMm,

    /// Non-ring dimensions. The mockups hardcoded ring-only fields with no conditional swap;
    /// D-012 requires the swap, so a necklace stores length and a bangle an inner diameter.
    @JsonKey(name: 'length_mm') double? lengthMm,
    @JsonKey(name: 'inner_dia_mm') double? innerDiaMm,
    @JsonKey(name: 'drop_mm') double? dropMm,
    String? notes,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,
  }) = _ProductSpec;

  factory ProductSpec.fromJson(Map<String, dynamic> json) => _$ProductSpecFromJson(json);

  /// '6-Prong Cathedral' if given, else the style's own label.
  String get settingLabel {
    final d = settingDetail?.trim();
    if (d != null && d.isNotEmpty) return d;
    return settingStyle?.label ?? '—';
  }

  /// A style of `other` with no detail typed is an incomplete spec, not a valid answer.
  bool get settingNeedsDetail =>
      (settingStyle?.needsDetail ?? false) && (settingDetail?.trim().isEmpty ?? true);

  bool get intentNeedsNote =>
      (designIntent?.needsDetail ?? false) && (designIntentNote?.trim().isEmpty ?? true);

  /// 'IN 14 · US 6.5 · UK N' — operators quote all three because customers arrive with any of
  /// them.
  String get ringSizeLabel {
    final parts = <String>[];
    if (ringSizeIn != null) parts.add('IN ${trimDecimal(ringSizeIn!)}');
    if (ringSizeUs != null) parts.add('US ${trimDecimal(ringSizeUs!)}');
    final uk = ringSizeUk?.trim();
    if (uk != null && uk.isNotEmpty) parts.add('UK $uk');
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  /// The dimension that matters for the given category — the conditional swap D-012 demands.
  String dimensionLabel(ProductCategory category) {
    if (category.usesRingSize) return ringSizeLabel;
    if (category.usesInnerDiameter && innerDiaMm != null) {
      return '${trimDecimal(innerDiaMm!)} mm inner Ø';
    }
    if (category.usesLength && lengthMm != null) return '${trimDecimal(lengthMm!)} mm length';
    if (category.usesDrop && dropMm != null) return '${trimDecimal(dropMm!)} mm drop';
    return '—';
  }

  /// Which fields the wizard still needs for this category before the step can pass.
  List<String> missingFor(ProductCategory category) {
    final gaps = <String>[];
    if (settingStyle == null) gaps.add('Setting style');
    if (settingNeedsDetail) gaps.add('Setting detail');
    if (intentNeedsNote) gaps.add('What matters most');
    if (category.usesRingSize && ringSizeIn == null && ringSizeUs == null) {
      gaps.add('Ring size');
    }
    if (category.usesInnerDiameter && innerDiaMm == null) gaps.add('Inner diameter');
    if (category.usesLength && lengthMm == null) gaps.add('Length');
    if (category.usesDrop && dropMm == null) gaps.add('Drop');
    return gaps;
  }
}

/// The metal specification: `metal_materials` ∪ `quick_specs` (D-012).
@freezed
abstract class MetalSpec with _$MetalSpec {
  const MetalSpec._();

  const factory MetalSpec({
    @JsonKey(name: 'job_id') required String jobId,
    @JsonKey(name: 'base_metal') @BaseMetalOrNull() BaseMetal? baseMetal,

    /// REQ-PUR-02. The mockups offered a flat purity list with no dependency on base metal, so
    /// 22K rose gold was selectable — which is not a product. See [purityIsValid].
    @MetalPurityOrNull() MetalPurity? purity,

    /// Only meaningful for gold.
    @MetalColorOrNull() MetalColor? color,

    /// '8.5 g' — the binding weight. `order_details` rendered this in gold as the one spec that
    /// governs the bench, then made it read-only with no way to record the actual.
    @JsonKey(name: 'target_weight_g') double? targetWeightG,

    /// '± 0.5 g'.
    @JsonKey(name: 'weight_tol_g') double? weightTolG,

    /// 'Client providing scrap or raw material'.
    @JsonKey(name: 'customer_supplied') @Default(false) bool customerSupplied,

    /// "18K, Maker's Mark, PT950" — hallmarking is an Indian-market requirement (D-002).
    String? hallmark,
    @JsonKey(name: 'alloy_notes') String? alloyNotes,

    /// REQ-GEM-03. False must SKIP the stone step; the mockup's CTA read PROCEED TO STONES
    /// even when the answer was No.
    @JsonKey(name: 'gemstone_inset') bool? gemstoneInset,

    /// REQ-FIN-04, minor units. `metal_specs` carries no currency column — the job's currency
    /// governs, so these are surfaced through [targetBudgetMin] / [targetBudgetMax].
    @JsonKey(name: 'target_budget_min') int? targetBudgetMinMinor,
    @JsonKey(name: 'target_budget_max') int? targetBudgetMaxMinor,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,
  }) = _MetalSpec;

  factory MetalSpec.fromJson(Map<String, dynamic> json) => _$MetalSpecFromJson(json);

  /// Pass `job.currency`. D-004: never a double, never a raw int in the UI.
  Money? targetBudgetMin(String currency) =>
      targetBudgetMinMinor == null ? null : Money(targetBudgetMinMinor!, currency);

  Money? targetBudgetMax(String currency) =>
      targetBudgetMaxMinor == null ? null : Money(targetBudgetMaxMinor!, currency);

  /// '₹80,000 – ₹1,20,000', or a single bound when only one was given.
  String budgetLabel(String currency) {
    final lo = targetBudgetMin(currency);
    final hi = targetBudgetMax(currency);
    if (lo == null && hi == null) return '—';
    if (lo != null && hi != null) {
      return '${lo.format(compact: true)} – ${hi.format(compact: true)}';
    }
    return (lo ?? hi)!.format(compact: true);
  }

  /// REQ-GEM-03: an explicit No skips the stone step. Null is "not answered yet", which must
  /// not skip anything.
  bool get skipsStoneStep => gemstoneInset == false;

  /// The dependency the mockups declared and never enforced. Null purity is incomplete, not
  /// invalid — the wizard reports that separately.
  bool get purityIsValid {
    final metal = baseMetal;
    final p = purity;
    if (metal == null || p == null) return true;
    return metal.purities.contains(p);
  }

  /// '18K Yellow Gold' / 'Pt 950 Platinum' — the alloy string casting needs.
  String get alloyLabel {
    final metal = baseMetal;
    if (metal == null) return '—';
    final parts = <String>[];
    if (purity != null) parts.add(purity!.label);
    if (metal.hasColor && color != null) parts.add(color!.label);
    parts.add(metal.label);
    return parts.join(' ');
  }

  /// '8.5 g ± 0.5 g' — the binding spec, quoted verbatim onto the QC checklist helper.
  String get weightLabel {
    final target = targetWeightG;
    if (target == null) return '—';
    final tol = weightTolG;
    return tol == null ? '${trimDecimal(target)} g' : '${trimDecimal(target)} g ± ${trimDecimal(tol)} g';
  }

  /// Whether a measured weight satisfies the binding spec. With no tolerance recorded, any
  /// weight passes — the bench is not held to a number nobody set.
  bool weightWithinTolerance(double measuredG) {
    final target = targetWeightG;
    final tol = weightTolG;
    if (target == null || tol == null) return true;
    return (measuredG - target).abs() <= tol;
  }
}

/// `requirements` — D-009. A shared citation for any spec line, so shop floor, QC and customer
/// argue about `REQ-MAT-01` rather than about "the metal thing".
@freezed
abstract class Requirement with _$Requirement {
  const Requirement._();

  const factory Requirement({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,

    /// 'REQ-MAT-01'. Shape enforced by a CHECK constraint.
    required String code,

    /// 'MAT' | 'PUR' | 'GEM' | 'FIN' | 'TML' | ...
    required String domain,

    /// 'Base Metal'.
    required String label,
    @JsonKey(name: 'value_text') String? valueText,
    @JsonKey(name: 'is_critical') @Default(false) bool isCritical,

    /// 'metal_specs.base_metal' — where the value came from, so a spec change can invalidate
    /// the QC item that cites it.
    @JsonKey(name: 'source_field') String? sourceField,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _Requirement;

  factory Requirement.fromJson(Map<String, dynamic> json) => _$RequirementFromJson(json);

  /// 'REQ-MAT-01 · Base Metal: 18K Yellow Gold'.
  String get citation {
    final v = valueText?.trim();
    return v == null || v.isEmpty ? '$code · $label' : '$code · $label: $v';
  }

  /// The two-digit sequence within the domain, for stable ordering of a spec sheet.
  int get sequence => int.tryParse(code.length >= 2 ? code.substring(code.length - 2) : '') ?? 0;
}

/// `job_references` — the captured references that satisfy D-011 rule 4.
@freezed
abstract class JobReference with _$JobReference {
  const JobReference._();

  const factory JobReference({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,

    /// D-001: 'RF-9921'.
    @JsonKey(name: 'ref_code') String? refCode,
    @JsonKey(name: 'attachment_id') String? attachmentId,
    @JsonKey(name: 'is_primary') @Default(false) bool isPrimary,
    String? note,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _JobReference;

  factory JobReference.fromJson(Map<String, dynamic> json) => _$JobReferenceFromJson(json);

  /// D-011 rule 4: a reference row only counts once it actually points at a file. A note on its
  /// own is not a reference.
  bool get hasFile => attachmentId != null;

  String get displayCode => refCode ?? 'Reference';
}
