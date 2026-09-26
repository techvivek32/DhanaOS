/// Local edits that can actually clear a field.
///
/// Freezed's `copyWith` reads a null argument as "leave this alone", which is exactly wrong for a
/// wizard: switching the base metal away from gold has to *remove* the colour, and moving from a
/// ring to a bangle has to *remove* the ring size. Carrying a stale value forward is how a job
/// bag ends up specifying "22K rose platinum".
///
/// So the edit helpers below take the same [Opt] the repository layer takes — `Opt(v)` sets,
/// `Opt.clear()` nulls, omitted leaves alone — and rebuild the record explicitly. The controller
/// hands one `Opt` map to both the local edit and the remote upsert, so the optimistic copy on
/// screen and the row in Postgres cannot disagree about what the operator meant.
library;

import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

/// `Opt(v)` when [value] is set, `Opt.clear()` when it is null. For turning a plain nullable into
/// the explicit three-state the write layer wants.
Opt<T> optOf<T extends Object>(T? value) =>
    value == null ? Opt<T>.clear() : Opt<T>(value);

T? _pick<T extends Object>(Opt<T>? field, T? current) =>
    field == null ? current : field.value;

extension ProductSpecEdit on ProductSpec {
  ProductSpec edit({
    Opt<SettingStyle>? settingStyle,
    Opt<String>? settingDetail,
    Opt<MetalFinish>? metalFinish,
    Opt<BandProfile>? bandProfile,
    Opt<FitProfile>? fit,
    Opt<SideStoneSetting>? sideStones,
    Opt<DesignIntent>? designIntent,
    Opt<String>? designIntentNote,
    Opt<double>? ringSizeIn,
    Opt<double>? ringSizeUs,
    Opt<String>? ringSizeUk,
    Opt<double>? bandWidthMm,
    Opt<double>? lengthMm,
    Opt<double>? innerDiaMm,
    Opt<double>? dropMm,
    Opt<String>? notes,
  }) =>
      ProductSpec(
        jobId: jobId,
        settingStyle: _pick(settingStyle, this.settingStyle),
        settingDetail: _pick(settingDetail, this.settingDetail),
        metalFinish: _pick(metalFinish, this.metalFinish),
        bandProfile: _pick(bandProfile, this.bandProfile),
        fit: _pick(fit, this.fit),
        sideStones: _pick(sideStones, this.sideStones),
        designIntent: _pick(designIntent, this.designIntent),
        designIntentNote: _pick(designIntentNote, this.designIntentNote),
        ringSizeIn: _pick(ringSizeIn, this.ringSizeIn),
        ringSizeUs: _pick(ringSizeUs, this.ringSizeUs),
        ringSizeUk: _pick(ringSizeUk, this.ringSizeUk),
        bandWidthMm: _pick(bandWidthMm, this.bandWidthMm),
        lengthMm: _pick(lengthMm, this.lengthMm),
        innerDiaMm: _pick(innerDiaMm, this.innerDiaMm),
        dropMm: _pick(dropMm, this.dropMm),
        notes: _pick(notes, this.notes),
        updatedAt: DateTime.now().toUtc(),
      );

  static ProductSpec blank(String jobId) =>
      ProductSpec(jobId: jobId, updatedAt: DateTime.now().toUtc());
}

extension MetalSpecEdit on MetalSpec {
  MetalSpec edit({
    Opt<BaseMetal>? baseMetal,
    Opt<MetalPurity>? purity,
    Opt<MetalColor>? color,
    Opt<double>? targetWeightG,
    Opt<double>? weightTolG,
    bool? customerSupplied,
    Opt<String>? hallmark,
    Opt<String>? alloyNotes,
    Opt<bool>? gemstoneInset,
    Opt<int>? targetBudgetMinMinor,
    Opt<int>? targetBudgetMaxMinor,
  }) =>
      MetalSpec(
        jobId: jobId,
        baseMetal: _pick(baseMetal, this.baseMetal),
        purity: _pick(purity, this.purity),
        color: _pick(color, this.color),
        targetWeightG: _pick(targetWeightG, this.targetWeightG),
        weightTolG: _pick(weightTolG, this.weightTolG),
        customerSupplied: customerSupplied ?? this.customerSupplied,
        hallmark: _pick(hallmark, this.hallmark),
        alloyNotes: _pick(alloyNotes, this.alloyNotes),
        gemstoneInset: _pick(gemstoneInset, this.gemstoneInset),
        targetBudgetMinMinor: _pick(targetBudgetMinMinor, this.targetBudgetMinMinor),
        targetBudgetMaxMinor: _pick(targetBudgetMaxMinor, this.targetBudgetMaxMinor),
        updatedAt: DateTime.now().toUtc(),
      );

  static MetalSpec blank(String jobId) =>
      MetalSpec(jobId: jobId, updatedAt: DateTime.now().toUtc());
}

extension DeliveryScheduleEdit on DeliverySchedule {
  DeliverySchedule edit({
    Opt<DateTime>? requestedDate,
    bool? hardDeadline,
    bool? partialAllowed,
    Priority? priority,
    int? dispatchBufferD,
    int? certBufferD,
    Opt<DateTime>? recommendedDone,
  }) =>
      DeliverySchedule(
        jobId: jobId,
        requestedDate: _pick(requestedDate, this.requestedDate),
        hardDeadline: hardDeadline ?? this.hardDeadline,
        partialAllowed: partialAllowed ?? this.partialAllowed,
        priority: priority ?? this.priority,
        dispatchBufferD: dispatchBufferD ?? this.dispatchBufferD,
        certBufferD: certBufferD ?? this.certBufferD,
        recommendedDone: _pick(recommendedDone, this.recommendedDone),
        updatedAt: DateTime.now().toUtc(),
      );

  static DeliverySchedule blank(String jobId, {Priority priority = Priority.standard}) =>
      DeliverySchedule(
        jobId: jobId,
        priority: priority,
        updatedAt: DateTime.now().toUtc(),
      );
}

extension AcceptanceCriteriaEdit on AcceptanceCriteria {
  AcceptanceCriteria edit({
    bool? matchCad,
    bool? highPolish,
    bool? sizeWeightConform,
    bool? strictTolerance,
    Opt<double>? toleranceMm,
    bool? stonesSecure,
    bool? symmetry,
    CertLab? certLab,
    Opt<String>? certLabOther,
    QualityAuthority? authority,
    Opt<String>? customerNotes,
  }) =>
      AcceptanceCriteria(
        jobId: jobId,
        matchCad: matchCad ?? this.matchCad,
        highPolish: highPolish ?? this.highPolish,
        sizeWeightConform: sizeWeightConform ?? this.sizeWeightConform,
        strictTolerance: strictTolerance ?? this.strictTolerance,
        toleranceMm: _pick(toleranceMm, this.toleranceMm),
        stonesSecure: stonesSecure ?? this.stonesSecure,
        symmetry: symmetry ?? this.symmetry,
        certLab: certLab ?? this.certLab,
        certLabOther: _pick(certLabOther, this.certLabOther),
        authority: authority ?? this.authority,
        customerNotes: _pick(customerNotes, this.customerNotes),
        updatedAt: DateTime.now().toUtc(),
      );

  /// The shipped defaults: five checks on, strict tolerance opt-in, IGI, jeweler signs off.
  /// Straight from `quality_acceptance` — the one screen whose defaults were considered.
  static AcceptanceCriteria blank(String jobId) =>
      AcceptanceCriteria(jobId: jobId, updatedAt: DateTime.now().toUtc());
}

extension StoneEdit on Stone {
  Stone edit({
    StoneRole? role,
    int? position,
    StoneSourcing? sourcing,
    Opt<StoneType>? stoneType,
    Opt<StoneOrigin>? origin,
    Opt<StoneShape>? shape,
    Opt<double>? carat,
    Opt<double>? lengthMm,
    Opt<double>? widthMm,
    Opt<double>? depthMm,
    Opt<DiamondColor>? color,
    Opt<String>? colorRange,
    Opt<DiamondClarity>? clarity,
    Opt<String>? clarityRange,
    Opt<DiamondCut>? cut,
    Opt<String>? treatment,
    Opt<String>? provenance,
    bool? certRequired,
    Opt<CertLab>? certLab,
    Opt<String>? certNumber,
    Opt<String>? certAttachment,
    Opt<String>? photoAttachment,
    Opt<int>? declaredValueMinor,
    Opt<String>? verifiedBy,
    Opt<DateTime>? verifiedAt,
    Opt<String>? receiptCode,
    bool? riskAck,
    Opt<String>? inventoryItemId,
    Opt<String>? notes,
  }) =>
      Stone(
        id: id,
        jobId: jobId,
        role: role ?? this.role,
        position: position ?? this.position,
        sourcing: sourcing ?? this.sourcing,
        stoneType: _pick(stoneType, this.stoneType),
        origin: _pick(origin, this.origin),
        shape: _pick(shape, this.shape),
        carat: _pick(carat, this.carat),
        lengthMm: _pick(lengthMm, this.lengthMm),
        widthMm: _pick(widthMm, this.widthMm),
        depthMm: _pick(depthMm, this.depthMm),
        color: _pick(color, this.color),
        colorRange: _pick(colorRange, this.colorRange),
        clarity: _pick(clarity, this.clarity),
        clarityRange: _pick(clarityRange, this.clarityRange),
        cut: _pick(cut, this.cut),
        treatment: _pick(treatment, this.treatment),
        provenance: _pick(provenance, this.provenance),
        certRequired: certRequired ?? this.certRequired,
        certLab: _pick(certLab, this.certLab),
        certNumber: _pick(certNumber, this.certNumber),
        certAttachment: _pick(certAttachment, this.certAttachment),
        photoAttachment: _pick(photoAttachment, this.photoAttachment),
        declaredValueMinor: _pick(declaredValueMinor, this.declaredValueMinor),
        verifiedBy: _pick(verifiedBy, this.verifiedBy),
        verifiedAt: _pick(verifiedAt, this.verifiedAt),
        receiptCode: _pick(receiptCode, this.receiptCode),
        riskAck: riskAck ?? this.riskAck,
        inventoryItemId: _pick(inventoryItemId, this.inventoryItemId),
        notes: _pick(notes, this.notes),
        createdAt: createdAt,
      );

  /// Coloured stones are not graded on the 4Cs, so moving a ruby onto a diamond's grade table —
  /// or off it — has to take the grades with it. The mockups drew one fixed 4C panel for every
  /// species, which is simply wrong for a sapphire.
  Stone reconciledForType() {
    if (usesFourCs) {
      return edit(treatment: const Opt.clear(), provenance: const Opt.clear());
    }
    return edit(
      color: const Opt.clear(),
      colorRange: const Opt.clear(),
      clarity: const Opt.clear(),
      clarityRange: const Opt.clear(),
      cut: const Opt.clear(),
    );
  }
}

extension MeleeParcelEdit on MeleeParcel {
  MeleeParcel edit({
    StoneSourcing? sourcing,
    StoneType? stoneType,
    Opt<StoneOrigin>? origin,
    StoneShape? shape,
    Opt<double>? sizeMinMm,
    Opt<double>? sizeMaxMm,
    Opt<double>? totalCtw,
    Opt<int>? pieceCount,
    Opt<String>? colorRange,
    Opt<String>? clarityRange,
    Opt<String>? notes,
  }) =>
      MeleeParcel(
        id: id,
        jobId: jobId,
        sourcing: sourcing ?? this.sourcing,
        stoneType: stoneType ?? this.stoneType,
        origin: _pick(origin, this.origin),
        shape: shape ?? this.shape,
        sizeMinMm: _pick(sizeMinMm, this.sizeMinMm),
        sizeMaxMm: _pick(sizeMaxMm, this.sizeMaxMm),
        totalCtw: _pick(totalCtw, this.totalCtw),
        pieceCount: _pick(pieceCount, this.pieceCount),
        colorRange: _pick(colorRange, this.colorRange),
        clarityRange: _pick(clarityRange, this.clarityRange),
        notes: _pick(notes, this.notes),
        createdAt: createdAt,
      );
}
