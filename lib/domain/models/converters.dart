/// JSON converters for every Postgres enum that crosses the wire.
///
/// Convention 6: an enum crossing the wire ALWAYS goes through `.wire` and `Xxx.parse(...)`.
/// Never `.name`, never `.toString()` — the Dart identifier and the Postgres value differ for
/// every multi-word value (`finalApp` vs `final_app`, `ifl` vs `if`, `returned` vs `return`),
/// so `.name` would silently write values Postgres rejects.
///
/// There are two converters per enum:
///
///   `XxxConverter()` — for a NOT NULL column
///   `XxxOrNull()`    — for a nullable column
///
/// json_serializable matches a converter to a field by its value type, so a nullable column
/// needs a converter whose value type is nullable. Spelling both out means the generated code
/// never depends on the generator's null-wrapping helper.
library;

import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/wire_enums.dart';
import 'package:json_annotation/json_annotation.dart';

/// `Xxx.parse` returns null for a value this build does not know, so a database that is AHEAD
/// of the app cannot crash it. On a NOT NULL column there is no null to fall back to, so fail
/// loudly with the offending value rather than inventing a default that would then be written
/// back over real data.
Never _unknown(String type, String wire) =>
    throw FormatException('Database sent a $type value this build does not know', wire);

abstract base class _Wire<T extends Object> implements JsonConverter<T, String> {
  const _Wire(this._parse, this._wire, this._type);

  final T? Function(String?) _parse;
  final String Function(T) _wire;
  final String _type;

  @override
  T fromJson(String json) => _parse(json) ?? _unknown(_type, json);

  @override
  String toJson(T object) => _wire(object);
}

abstract base class _WireOrNull<T extends Object> implements JsonConverter<T?, String?> {
  const _WireOrNull(this._parse, this._wire);

  final T? Function(String?) _parse;
  final String Function(T) _wire;

  @override
  T? fromJson(String? json) => _parse(json);

  @override
  String? toJson(T? object) => object == null ? null : _wire(object);
}

// ---------------------------------------------------------------- identity (D-008)

String _wUserRole(UserRole v) => v.wire;

final class UserRoleConverter extends _Wire<UserRole> {
  const UserRoleConverter() : super(UserRole.parse, _wUserRole, 'UserRole');
}

final class UserRoleOrNull extends _WireOrNull<UserRole> {
  const UserRoleOrNull() : super(UserRole.parse, _wUserRole);
}

String _wPrincipalClass(PrincipalClass v) => v.wire;

final class PrincipalClassConverter extends _Wire<PrincipalClass> {
  const PrincipalClassConverter() : super(PrincipalClass.parse, _wPrincipalClass, 'PrincipalClass');
}

final class PrincipalClassOrNull extends _WireOrNull<PrincipalClass> {
  const PrincipalClassOrNull() : super(PrincipalClass.parse, _wPrincipalClass);
}

String _wPartnerKind(PartnerKind v) => v.wire;

final class PartnerKindConverter extends _Wire<PartnerKind> {
  const PartnerKindConverter() : super(PartnerKind.parse, _wPartnerKind, 'PartnerKind');
}

final class PartnerKindOrNull extends _WireOrNull<PartnerKind> {
  const PartnerKindOrNull() : super(PartnerKind.parse, _wPartnerKind);
}

// ---------------------------------------------------------------- lifecycle (D-002) and job shape

String _wLifecycleStage(LifecycleStage v) => v.wire;

final class LifecycleStageConverter extends _Wire<LifecycleStage> {
  const LifecycleStageConverter() : super(LifecycleStage.parse, _wLifecycleStage, 'LifecycleStage');
}

final class LifecycleStageOrNull extends _WireOrNull<LifecycleStage> {
  const LifecycleStageOrNull() : super(LifecycleStage.parse, _wLifecycleStage);
}

String _wStageState(StageState v) => v.wire;

final class StageStateConverter extends _Wire<StageState> {
  const StageStateConverter() : super(StageState.parse, _wStageState, 'StageState');
}

final class StageStateOrNull extends _WireOrNull<StageState> {
  const StageStateOrNull() : super(StageState.parse, _wStageState);
}

String _wJobStatus(JobStatus v) => v.wire;

final class JobStatusConverter extends _Wire<JobStatus> {
  const JobStatusConverter() : super(JobStatus.parse, _wJobStatus, 'JobStatus');
}

final class JobStatusOrNull extends _WireOrNull<JobStatus> {
  const JobStatusOrNull() : super(JobStatus.parse, _wJobStatus);
}

String _wJobType(JobType v) => v.wire;

final class JobTypeConverter extends _Wire<JobType> {
  const JobTypeConverter() : super(JobType.parse, _wJobType, 'JobType');
}

final class JobTypeOrNull extends _WireOrNull<JobType> {
  const JobTypeOrNull() : super(JobType.parse, _wJobType);
}

String _wProductCategory(ProductCategory v) => v.wire;

final class ProductCategoryConverter extends _Wire<ProductCategory> {
  const ProductCategoryConverter() : super(ProductCategory.parse, _wProductCategory, 'ProductCategory');
}

final class ProductCategoryOrNull extends _WireOrNull<ProductCategory> {
  const ProductCategoryOrNull() : super(ProductCategory.parse, _wProductCategory);
}

String _wProductSubStyle(ProductSubStyle v) => v.wire;

final class ProductSubStyleConverter extends _Wire<ProductSubStyle> {
  const ProductSubStyleConverter() : super(ProductSubStyle.parse, _wProductSubStyle, 'ProductSubStyle');
}

final class ProductSubStyleOrNull extends _WireOrNull<ProductSubStyle> {
  const ProductSubStyleOrNull() : super(ProductSubStyle.parse, _wProductSubStyle);
}

String _wPriority(Priority v) => v.wire;

final class PriorityConverter extends _Wire<Priority> {
  const PriorityConverter() : super(Priority.parse, _wPriority, 'Priority');
}

final class PriorityOrNull extends _WireOrNull<Priority> {
  const PriorityOrNull() : super(Priority.parse, _wPriority);
}

// ---------------------------------------------------------------- metal

String _wBaseMetal(BaseMetal v) => v.wire;

final class BaseMetalConverter extends _Wire<BaseMetal> {
  const BaseMetalConverter() : super(BaseMetal.parse, _wBaseMetal, 'BaseMetal');
}

final class BaseMetalOrNull extends _WireOrNull<BaseMetal> {
  const BaseMetalOrNull() : super(BaseMetal.parse, _wBaseMetal);
}

String _wMetalPurity(MetalPurity v) => v.wire;

final class MetalPurityConverter extends _Wire<MetalPurity> {
  const MetalPurityConverter() : super(MetalPurity.parse, _wMetalPurity, 'MetalPurity');
}

final class MetalPurityOrNull extends _WireOrNull<MetalPurity> {
  const MetalPurityOrNull() : super(MetalPurity.parse, _wMetalPurity);
}

String _wMetalColor(MetalColor v) => v.wire;

final class MetalColorConverter extends _Wire<MetalColor> {
  const MetalColorConverter() : super(MetalColor.parse, _wMetalColor, 'MetalColor');
}

final class MetalColorOrNull extends _WireOrNull<MetalColor> {
  const MetalColorOrNull() : super(MetalColor.parse, _wMetalColor);
}

String _wMetalFinish(MetalFinish v) => v.wire;

final class MetalFinishConverter extends _Wire<MetalFinish> {
  const MetalFinishConverter() : super(MetalFinish.parse, _wMetalFinish, 'MetalFinish');
}

final class MetalFinishOrNull extends _WireOrNull<MetalFinish> {
  const MetalFinishOrNull() : super(MetalFinish.parse, _wMetalFinish);
}

String _wBandProfile(BandProfile v) => v.wire;

final class BandProfileConverter extends _Wire<BandProfile> {
  const BandProfileConverter() : super(BandProfile.parse, _wBandProfile, 'BandProfile');
}

final class BandProfileOrNull extends _WireOrNull<BandProfile> {
  const BandProfileOrNull() : super(BandProfile.parse, _wBandProfile);
}

String _wFitProfile(FitProfile v) => v.wire;

final class FitProfileConverter extends _Wire<FitProfile> {
  const FitProfileConverter() : super(FitProfile.parse, _wFitProfile, 'FitProfile');
}

final class FitProfileOrNull extends _WireOrNull<FitProfile> {
  const FitProfileOrNull() : super(FitProfile.parse, _wFitProfile);
}

// ---------------------------------------------------------------- design

String _wSettingStyle(SettingStyle v) => v.wire;

final class SettingStyleConverter extends _Wire<SettingStyle> {
  const SettingStyleConverter() : super(SettingStyle.parse, _wSettingStyle, 'SettingStyle');
}

final class SettingStyleOrNull extends _WireOrNull<SettingStyle> {
  const SettingStyleOrNull() : super(SettingStyle.parse, _wSettingStyle);
}

String _wSideStoneSetting(SideStoneSetting v) => v.wire;

final class SideStoneSettingConverter extends _Wire<SideStoneSetting> {
  const SideStoneSettingConverter() : super(SideStoneSetting.parse, _wSideStoneSetting, 'SideStoneSetting');
}

final class SideStoneSettingOrNull extends _WireOrNull<SideStoneSetting> {
  const SideStoneSettingOrNull() : super(SideStoneSetting.parse, _wSideStoneSetting);
}

String _wDesignIntent(DesignIntent v) => v.wire;

final class DesignIntentConverter extends _Wire<DesignIntent> {
  const DesignIntentConverter() : super(DesignIntent.parse, _wDesignIntent, 'DesignIntent');
}

final class DesignIntentOrNull extends _WireOrNull<DesignIntent> {
  const DesignIntentOrNull() : super(DesignIntent.parse, _wDesignIntent);
}

// ---------------------------------------------------------------- stones

String _wStoneType(StoneType v) => v.wire;

final class StoneTypeConverter extends _Wire<StoneType> {
  const StoneTypeConverter() : super(StoneType.parse, _wStoneType, 'StoneType');
}

final class StoneTypeOrNull extends _WireOrNull<StoneType> {
  const StoneTypeOrNull() : super(StoneType.parse, _wStoneType);
}

String _wStoneOrigin(StoneOrigin v) => v.wire;

final class StoneOriginConverter extends _Wire<StoneOrigin> {
  const StoneOriginConverter() : super(StoneOrigin.parse, _wStoneOrigin, 'StoneOrigin');
}

final class StoneOriginOrNull extends _WireOrNull<StoneOrigin> {
  const StoneOriginOrNull() : super(StoneOrigin.parse, _wStoneOrigin);
}

String _wStoneShape(StoneShape v) => v.wire;

final class StoneShapeConverter extends _Wire<StoneShape> {
  const StoneShapeConverter() : super(StoneShape.parse, _wStoneShape, 'StoneShape');
}

final class StoneShapeOrNull extends _WireOrNull<StoneShape> {
  const StoneShapeOrNull() : super(StoneShape.parse, _wStoneShape);
}

String _wStoneSourcing(StoneSourcing v) => v.wire;

final class StoneSourcingConverter extends _Wire<StoneSourcing> {
  const StoneSourcingConverter() : super(StoneSourcing.parse, _wStoneSourcing, 'StoneSourcing');
}

final class StoneSourcingOrNull extends _WireOrNull<StoneSourcing> {
  const StoneSourcingOrNull() : super(StoneSourcing.parse, _wStoneSourcing);
}

String _wStoneRole(StoneRole v) => v.wire;

final class StoneRoleConverter extends _Wire<StoneRole> {
  const StoneRoleConverter() : super(StoneRole.parse, _wStoneRole, 'StoneRole');
}

final class StoneRoleOrNull extends _WireOrNull<StoneRole> {
  const StoneRoleOrNull() : super(StoneRole.parse, _wStoneRole);
}

String _wDiamondColor(DiamondColor v) => v.wire;

final class DiamondColorConverter extends _Wire<DiamondColor> {
  const DiamondColorConverter() : super(DiamondColor.parse, _wDiamondColor, 'DiamondColor');
}

final class DiamondColorOrNull extends _WireOrNull<DiamondColor> {
  const DiamondColorOrNull() : super(DiamondColor.parse, _wDiamondColor);
}

String _wDiamondClarity(DiamondClarity v) => v.wire;

final class DiamondClarityConverter extends _Wire<DiamondClarity> {
  const DiamondClarityConverter() : super(DiamondClarity.parse, _wDiamondClarity, 'DiamondClarity');
}

final class DiamondClarityOrNull extends _WireOrNull<DiamondClarity> {
  const DiamondClarityOrNull() : super(DiamondClarity.parse, _wDiamondClarity);
}

String _wDiamondCut(DiamondCut v) => v.wire;

final class DiamondCutConverter extends _Wire<DiamondCut> {
  const DiamondCutConverter() : super(DiamondCut.parse, _wDiamondCut, 'DiamondCut');
}

final class DiamondCutOrNull extends _WireOrNull<DiamondCut> {
  const DiamondCutOrNull() : super(DiamondCut.parse, _wDiamondCut);
}

// ---------------------------------------------------------------- certification

String _wCertLab(CertLab v) => v.wire;

final class CertLabConverter extends _Wire<CertLab> {
  const CertLabConverter() : super(CertLab.parse, _wCertLab, 'CertLab');
}

final class CertLabOrNull extends _WireOrNull<CertLab> {
  const CertLabOrNull() : super(CertLab.parse, _wCertLab);
}

String _wCertStatus(CertStatus v) => v.wire;

final class CertStatusConverter extends _Wire<CertStatus> {
  const CertStatusConverter() : super(CertStatus.parse, _wCertStatus, 'CertStatus');
}

final class CertStatusOrNull extends _WireOrNull<CertStatus> {
  const CertStatusOrNull() : super(CertStatus.parse, _wCertStatus);
}

// ---------------------------------------------------------------- commercial (D-003, D-004)

String _wPricingBasis(PricingBasis v) => v.wire;

final class PricingBasisConverter extends _Wire<PricingBasis> {
  const PricingBasisConverter() : super(PricingBasis.parse, _wPricingBasis, 'PricingBasis');
}

final class PricingBasisOrNull extends _WireOrNull<PricingBasis> {
  const PricingBasisOrNull() : super(PricingBasis.parse, _wPricingBasis);
}

String _wSuppliedBy(SuppliedBy v) => v.wire;

final class SuppliedByConverter extends _Wire<SuppliedBy> {
  const SuppliedByConverter() : super(SuppliedBy.parse, _wSuppliedBy, 'SuppliedBy');
}

final class SuppliedByOrNull extends _WireOrNull<SuppliedBy> {
  const SuppliedByOrNull() : super(SuppliedBy.parse, _wSuppliedBy);
}

String _wCostCategory(CostCategory v) => v.wire;

final class CostCategoryConverter extends _Wire<CostCategory> {
  const CostCategoryConverter() : super(CostCategory.parse, _wCostCategory, 'CostCategory');
}

final class CostCategoryOrNull extends _WireOrNull<CostCategory> {
  const CostCategoryOrNull() : super(CostCategory.parse, _wCostCategory);
}

String _wQuoteStatus(QuoteStatus v) => v.wire;

final class QuoteStatusConverter extends _Wire<QuoteStatus> {
  const QuoteStatusConverter() : super(QuoteStatus.parse, _wQuoteStatus, 'QuoteStatus');
}

final class QuoteStatusOrNull extends _WireOrNull<QuoteStatus> {
  const QuoteStatusOrNull() : super(QuoteStatus.parse, _wQuoteStatus);
}

String _wApprovalGateKind(ApprovalGateKind v) => v.wire;

final class ApprovalGateKindConverter extends _Wire<ApprovalGateKind> {
  const ApprovalGateKindConverter() : super(ApprovalGateKind.parse, _wApprovalGateKind, 'ApprovalGateKind');
}

final class ApprovalGateKindOrNull extends _WireOrNull<ApprovalGateKind> {
  const ApprovalGateKindOrNull() : super(ApprovalGateKind.parse, _wApprovalGateKind);
}

String _wApprovalGateState(ApprovalGateState v) => v.wire;

final class ApprovalGateStateConverter extends _Wire<ApprovalGateState> {
  const ApprovalGateStateConverter() : super(ApprovalGateState.parse, _wApprovalGateState, 'ApprovalGateState');
}

final class ApprovalGateStateOrNull extends _WireOrNull<ApprovalGateState> {
  const ApprovalGateStateOrNull() : super(ApprovalGateState.parse, _wApprovalGateState);
}

// ---------------------------------------------------------------- quality

String _wQualityAuthority(QualityAuthority v) => v.wire;

final class QualityAuthorityConverter extends _Wire<QualityAuthority> {
  const QualityAuthorityConverter() : super(QualityAuthority.parse, _wQualityAuthority, 'QualityAuthority');
}

final class QualityAuthorityOrNull extends _WireOrNull<QualityAuthority> {
  const QualityAuthorityOrNull() : super(QualityAuthority.parse, _wQualityAuthority);
}

String _wQcStatus(QcStatus v) => v.wire;

final class QcStatusConverter extends _Wire<QcStatus> {
  const QcStatusConverter() : super(QcStatus.parse, _wQcStatus, 'QcStatus');
}

final class QcStatusOrNull extends _WireOrNull<QcStatus> {
  const QcStatusOrNull() : super(QcStatus.parse, _wQcStatus);
}

// ---------------------------------------------------------------- logistics

String _wDispatchRouting(DispatchRouting v) => v.wire;

final class DispatchRoutingConverter extends _Wire<DispatchRouting> {
  const DispatchRoutingConverter() : super(DispatchRouting.parse, _wDispatchRouting, 'DispatchRouting');
}

final class DispatchRoutingOrNull extends _WireOrNull<DispatchRouting> {
  const DispatchRoutingOrNull() : super(DispatchRouting.parse, _wDispatchRouting);
}

String _wCourier(Courier v) => v.wire;

final class CourierConverter extends _Wire<Courier> {
  const CourierConverter() : super(Courier.parse, _wCourier, 'Courier');
}

final class CourierOrNull extends _WireOrNull<Courier> {
  const CourierOrNull() : super(Courier.parse, _wCourier);
}

String _wShipmentLeg(ShipmentLeg v) => v.wire;

final class ShipmentLegConverter extends _Wire<ShipmentLeg> {
  const ShipmentLegConverter() : super(ShipmentLeg.parse, _wShipmentLeg, 'ShipmentLeg');
}

final class ShipmentLegOrNull extends _WireOrNull<ShipmentLeg> {
  const ShipmentLegOrNull() : super(ShipmentLeg.parse, _wShipmentLeg);
}

String _wShipmentStatus(ShipmentStatus v) => v.wire;

final class ShipmentStatusConverter extends _Wire<ShipmentStatus> {
  const ShipmentStatusConverter() : super(ShipmentStatus.parse, _wShipmentStatus, 'ShipmentStatus');
}

final class ShipmentStatusOrNull extends _WireOrNull<ShipmentStatus> {
  const ShipmentStatusOrNull() : super(ShipmentStatus.parse, _wShipmentStatus);
}

// ---------------------------------------------------------------- inventory

String _wStockKind(StockKind v) => v.wire;

final class StockKindConverter extends _Wire<StockKind> {
  const StockKindConverter() : super(StockKind.parse, _wStockKind, 'StockKind');
}

final class StockKindOrNull extends _WireOrNull<StockKind> {
  const StockKindOrNull() : super(StockKind.parse, _wStockKind);
}

String _wStockTxnKind(StockTxnKind v) => v.wire;

final class StockTxnKindConverter extends _Wire<StockTxnKind> {
  const StockTxnKindConverter() : super(StockTxnKind.parse, _wStockTxnKind, 'StockTxnKind');
}

final class StockTxnKindOrNull extends _WireOrNull<StockTxnKind> {
  const StockTxnKindOrNull() : super(StockTxnKind.parse, _wStockTxnKind);
}

String _wUom(Uom v) => v.wire;

final class UomConverter extends _Wire<Uom> {
  const UomConverter() : super(Uom.parse, _wUom, 'Uom');
}

final class UomOrNull extends _WireOrNull<Uom> {
  const UomOrNull() : super(Uom.parse, _wUom);
}

// ---------------------------------------------------------------- collaboration

String _wActivityKind(ActivityKind v) => v.wire;

final class ActivityKindConverter extends _Wire<ActivityKind> {
  const ActivityKindConverter() : super(ActivityKind.parse, _wActivityKind, 'ActivityKind');
}

final class ActivityKindOrNull extends _WireOrNull<ActivityKind> {
  const ActivityKindOrNull() : super(ActivityKind.parse, _wActivityKind);
}

String _wAttachmentKind(AttachmentKind v) => v.wire;

final class AttachmentKindConverter extends _Wire<AttachmentKind> {
  const AttachmentKindConverter() : super(AttachmentKind.parse, _wAttachmentKind, 'AttachmentKind');
}

final class AttachmentKindOrNull extends _WireOrNull<AttachmentKind> {
  const AttachmentKindOrNull() : super(AttachmentKind.parse, _wAttachmentKind);
}

String _wActionSeverity(ActionSeverity v) => v.wire;

final class ActionSeverityConverter extends _Wire<ActionSeverity> {
  const ActionSeverityConverter() : super(ActionSeverity.parse, _wActionSeverity, 'ActionSeverity');
}

final class ActionSeverityOrNull extends _WireOrNull<ActionSeverity> {
  const ActionSeverityOrNull() : super(ActionSeverity.parse, _wActionSeverity);
}
