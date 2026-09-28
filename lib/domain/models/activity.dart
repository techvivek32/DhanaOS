/// `activity_events`, `thread_posts`, and the `v_digital_thread` union over both.
///
/// `job_detail`'s core mechanic: human posts interleave chronologically with system events in
/// ONE stream. `certification` titled the same feed an "Immutable Audit Trail" — which is why
/// `activity_events` has UPDATE and DELETE revoked in Postgres, not merely by convention.
library;

import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'activity.freezed.dart';
part 'activity.g.dart';

/// An immutable audit row. Written by triggers and by `fn_*` procedures — the client inserts
/// these only for actions that have no server-side procedure.
@freezed
abstract class ActivityEvent with _$ActivityEvent {
  const ActivityEvent._();

  const factory ActivityEvent({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @ActivityKindConverter() required ActivityKind kind,
    @JsonKey(name: 'actor_id') String? actorId,

    /// 'System', 'IGI Antwerp', 'Logistics' — an actor with no account in this org.
    @JsonKey(name: 'actor_label') String? actorLabel,
    @LifecycleStageOrNull() LifecycleStage? stage,

    /// 'Stage Changed: Casting'.
    required String summary,

    /// 'System updated status automatically.'
    String? detail,
    @Default(<String, dynamic>{}) Map<String, dynamic> payload,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _ActivityEvent;

  factory ActivityEvent.fromJson(Map<String, dynamic> json) => _$ActivityEventFromJson(json);

  /// An event with no account behind it was written by a trigger.
  bool get isSystem => actorId == null;

  String get actorDisplay => actorLabel ?? 'System';

  /// Approvals and rejections are the rows an auditor reads first.
  bool get isDecision => kind == ActivityKind.approved || kind == ActivityKind.rejected;
}

/// A human post on the job. `isInternal` hides it from the customer portal — the mockups had
/// one feed for everybody, which meant shop-floor chatter was customer-visible by default.
@freezed
abstract class ThreadPost with _$ThreadPost {
  const ThreadPost._();

  const factory ThreadPost({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @JsonKey(name: 'author_id') String? authorId,

    /// For an external actor without an account.
    @JsonKey(name: 'author_label') String? authorLabel,
    @LifecycleStageOrNull() LifecycleStage? stage,
    required String body,
    @JsonKey(name: 'is_internal') @Default(false) bool isInternal,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'edited_at') DateTime? editedAt,
  }) = _ThreadPost;

  factory ThreadPost.fromJson(Map<String, dynamic> json) => _$ThreadPostFromJson(json);

  bool get isEdited => editedAt != null;

  bool get isCustomerVisible => !isInternal;
}

/// `v_digital_thread` — one chronological stream of system events and human posts.
///
/// A sealed union so a single `ListView` can render both without a nullable-field-per-variant
/// row model, and so adding a third entry kind later is a compile error everywhere it matters
/// rather than a silent fall-through. The discriminator is the view's own `entry_type` column.
@Freezed(unionKey: 'entry_type', unionValueCase: FreezedUnionCase.none)
sealed class ThreadEntry with _$ThreadEntry {
  const ThreadEntry._();

  /// A row from `activity_events`.
  const factory ThreadEntry.event({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @JsonKey(name: 'actor_id') String? actorId,
    @JsonKey(name: 'actor_label') String? actorLabel,
    @LifecycleStageOrNull() LifecycleStage? stage,

    /// The view maps `activity_events.summary` into `body` so both branches share a column.
    required String body,
    @JsonKey(name: 'is_internal') @Default(false) bool isInternal,
    @JsonKey(name: 'created_at') required DateTime createdAt,

    /// `activity_kind` as text, under the view's `sub_kind` column.
    @JsonKey(name: 'sub_kind') @ActivityKindOrNull() ActivityKind? activityKind,
    String? detail,
  }) = ThreadEventEntry;

  /// A row from `thread_posts`.
  const factory ThreadEntry.post({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @JsonKey(name: 'actor_id') String? actorId,
    @JsonKey(name: 'actor_label') String? actorLabel,
    @LifecycleStageOrNull() LifecycleStage? stage,
    required String body,
    @JsonKey(name: 'is_internal') @Default(false) bool isInternal,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = ThreadPostEntry;

  factory ThreadEntry.fromJson(Map<String, dynamic> json) => _$ThreadEntryFromJson(json);

  bool get isEvent => this is ThreadEventEntry;
  bool get isPost => this is ThreadPostEntry;

  /// System rows have no account behind them.
  bool get isSystem => actorId == null;

  String get actorDisplay => actorLabel ?? 'System';

  /// Hidden from the customer portal. Events are never internal — the audit trail is the
  /// record the customer is entitled to see.
  bool get isCustomerVisible => !isInternal;

  /// Newest first, which is how `job_detail` ordered the feed. Passed to `List.sort`, so a
  /// screen never re-derives the ordering rule.
  static int newestFirst(ThreadEntry a, ThreadEntry b) => b.createdAt.compareTo(a.createdAt);

  static int oldestFirst(ThreadEntry a, ThreadEntry b) => a.createdAt.compareTo(b.createdAt);
}
