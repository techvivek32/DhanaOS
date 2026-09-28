/// `partners` — casters, gem labs, stone suppliers, couriers and hubs.
///
/// D-008: a partner principal sees only jobs with a stage assigned to that partner. A vendor
/// seeing another vendor's jobs is a business-ending defect.
library;

import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'partner.freezed.dart';
part 'partner.g.dart';

@freezed
abstract class Partner with _$Partner {
  const Partner._();

  const factory Partner({
    required String id,
    @JsonKey(name: 'org_id') required String orgId,
    @PartnerKindConverter() required PartnerKind kind,

    /// "Patel Casting Works", "IGI Antwerp".
    required String name,
    @JsonKey(name: 'contact_name') String? contactName,
    String? email,
    String? phone,
    @Default(<String, dynamic>{}) Map<String, dynamic> address,
    String? gstin,
    @JsonKey(name: 'is_active') @Default(true) bool isActive,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _Partner;

  factory Partner.fromJson(Map<String, dynamic> json) => _$PartnerFromJson(json);

  /// Which rail stage this partner can be assigned to. Casting and certification are the only
  /// stages that leave the building.
  LifecycleStage? get servesStage => switch (kind) {
        PartnerKind.casting => LifecycleStage.casting,
        PartnerKind.lab => LifecycleStage.cert,
        PartnerKind.stoneSupplier ||
        PartnerKind.courier ||
        PartnerKind.hub ||
        PartnerKind.other => null,
      };

  bool canTakeStage(LifecycleStage stage) => servesStage == stage;

  /// A partner who raises a GST invoice for job work must be registered; unregistered vendors
  /// put the reverse-charge burden on the org.
  bool get isGstRegistered => (gstin?.trim().length ?? 0) >= 15;

  /// "Patel Casting Works · Casting"
  String get displayName => '$name · ${kind.label}';
}
