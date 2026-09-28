/// `resources` — the in-house things that close a stage.
///
/// The mockups credited stage completions to "PR-02" (a printer), "Bench 4", "Forge-A" and
/// "Marco V." — some machines, some people. Both close a stage, so both are resources.
library;

import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'resource.freezed.dart';
part 'resource.g.dart';

@freezed
abstract class Resource with _$Resource {
  const Resource._();

  const factory Resource({
    required String id,
    @JsonKey(name: 'org_id') required String orgId,

    /// "PR-02", "Bench 4", "Forge-A" — what the timeline prints as "Completed by PR-02".
    required String code,
    required String label,

    /// The rail stage this resource serves, so the completion sheet can offer only the
    /// machines and benches that belong to the stage being closed.
    @LifecycleStageOrNull() LifecycleStage? stage,

    /// Set when the resource is a person with a login. Null means it is equipment.
    @JsonKey(name: 'user_id') String? userId,
    @JsonKey(name: 'is_active') @Default(true) bool isActive,
  }) = _Resource;

  factory Resource.fromJson(Map<String, dynamic> json) => _$ResourceFromJson(json);

  /// Equipment has no login. A machine cannot hold a role, so it can never be the actor on an
  /// approval — only on a completion.
  bool get isEquipment => userId == null;

  bool get isPerson => userId != null;

  /// "Forge-A — Casting" on a picker row.
  String get displayLabel => stage == null ? '$code — $label' : '$code — $label · ${stage!.label}';
}
