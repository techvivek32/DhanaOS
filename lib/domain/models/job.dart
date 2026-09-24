/// `jobs` and the `v_job_list` view.
///
/// D-005: a job has NO mutable status column for its position in the pipeline. `currentStage`
/// is a trigger-maintained cache over `job_stages`; the rail in `job_stage.dart` is the truth.
/// `status` is orthogonal to stage — a job can be `onHold` while sitting at `casting`.
library;

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:dhanaos/domain/models/wire_enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'job.freezed.dart';
part 'job.g.dart';

@freezed
class Job with _$Job {
  const Job._();

  const factory Job({
    required String id,
    @JsonKey(name: 'org_id') required String orgId,

    /// D-001. Exactly one of these is set: `DRAFT-992A` before commit, `DH-2026-01842` after.
    /// Read `displayCode`, never either field directly.
    @JsonKey(name: 'draft_code') String? draftCode,
    String? code,
    @JsonKey(name: 'customer_id') String? customerId,
    @JsonKey(name: 'job_type') @JobTypeOrNull() JobType? jobType,
    @ProductCategoryOrNull() ProductCategory? category,

    /// D-012: `product_selection` showed a flat list, but downstream screens displayed
    /// "Engagement Ring" — a sub-style, not a category. Both are stored.
    @JsonKey(name: 'sub_style') @ProductSubStyleOrNull() ProductSubStyle? subStyle,

    /// "Solitaire Crown v2.FINAL".
    String? title,
    @Default(1) int quantity,
    @JobStatusConverter() @Default(JobStatus.draft) JobStatus status,
    @PriorityConverter() @Default(Priority.standard) Priority priority,

    /// D-005 cache only. The source of truth is the newest `job_stages` row with
    /// `state = active`; this exists so a 200-row list does not need 200 sub-queries.
    @JsonKey(name: 'current_stage') @LifecycleStageOrNull() LifecycleStage? currentStage,
    @JsonKey(name: 'stage_entered_at') DateTime? stageEnteredAt,

    /// Cross-cutting flags, orthogonal to stage. "3 At Risk" on the dashboard reads this.
    @JsonKey(name: 'is_at_risk') @Default(false) bool isAtRisk,
    @JsonKey(name: 'hold_reason') String? holdReason,
    @JsonKey(name: 'cancel_reason') String? cancelReason,

    /// Date columns, so they arrive as a local midnight rather than an instant.
    @JsonKey(name: 'requested_delivery') DateTime? requestedDelivery,
    @JsonKey(name: 'promised_delivery') DateTime? promisedDelivery,
    @JsonKey(name: 'hard_deadline') @Default(false) bool hardDeadline,
    @JsonKey(name: 'partial_allowed') @Default(true) bool partialAllowed,
    @Default('INR') String currency,

    /// Resumable intake: which wizard step this draft reached.
    @JsonKey(name: 'wizard_step') @Default(1) int wizardStep,
    @JsonKey(name: 'created_by') String? createdBy,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,

    /// When `draftCode` became `code`.
    @JsonKey(name: 'committed_at') DateTime? committedAt,
    @JsonKey(name: 'closed_at') DateTime? closedAt,
  }) = _Job;

  factory Job.fromJson(Map<String, dynamic> json) => _$JobFromJson(json);

  /// D-001. The SQL guarantees at least one identity, so this never renders an empty cell.
  String get displayCode => code ?? draftCode ?? '—';

  /// "Solitaire Crown v2.FINAL" if titled, else the code — a list row must always say
  /// something specific.
  String get displayTitle {
    final t = title?.trim();
    return t == null || t.isEmpty ? displayCode : t;
  }

  bool get isDraft => code == null;
  bool get isCommitted => code != null;
  bool get isOpen => status.isOpen;
  bool get isOnHold => status == JobStatus.onHold;

  /// A client's own stone opens the goods-in custody flow. The mockups had a `Reset Stone` job
  /// type and a "Verified & Logged in Inventory" chip with no record behind it.
  bool get takesCustody => jobType?.takesCustody ?? false;

  /// The mockup rendered this as "1d in stage". Computed here rather than read from
  /// `v_job_list.time_in_stage` because PostgREST renders a Postgres interval as prose
  /// ("1 day 04:05:06"), which is not worth parsing when we already hold the instant.
  Duration? get timeInStage {
    final since = stageEnteredAt;
    return since == null ? null : DateTime.now().toUtc().difference(since.toUtc());
  }

  /// "DUE TODAY" / "DUE TMRW".
  bool get dueSoon => _dueWithin(1);

  bool get overdue {
    final due = requestedDelivery;
    if (due == null || !isOpen) return false;
    return _dateOnly(due).isBefore(_today);
  }

  bool _dueWithin(int days) {
    final due = requestedDelivery;
    if (due == null || !isOpen) return false;
    return !_dateOnly(due).isAfter(_today.add(Duration(days: days)));
  }

  /// Whole days until the requested date; negative when late.
  int? get daysToDue {
    final due = requestedDelivery;
    return due == null ? null : _dateOnly(due).difference(_today).inDays;
  }

  Money money(int minor) => Money(minor, currency);
  Money get zero => Money(0, currency);
}

/// `v_job_list` — one row per job, already joined to customer, active assignment and approved
/// quote. Read this for every list, board and queue; read [Job] only when editing.
@freezed
class JobListItem with _$JobListItem {
  const JobListItem._();

  const factory JobListItem({
    required String id,
    @JsonKey(name: 'org_id') required String orgId,

    /// `coalesce(code, draft_code)` — resolved in SQL so sorting a list sorts on one column.
    @JsonKey(name: 'display_code') required String displayCode,
    String? code,
    @JsonKey(name: 'draft_code') String? draftCode,
    String? title,
    @JobStatusConverter() required JobStatus status,
    @PriorityConverter() required Priority priority,
    @JsonKey(name: 'current_stage') @LifecycleStageOrNull() LifecycleStage? currentStage,
    @JsonKey(name: 'stage_entered_at') DateTime? stageEnteredAt,
    @Default(1) int quantity,
    @JsonKey(name: 'requested_delivery') DateTime? requestedDelivery,
    @JsonKey(name: 'promised_delivery') DateTime? promisedDelivery,
    @Default('INR') String currency,
    @JsonKey(name: 'customer_id') String? customerId,
    @JsonKey(name: 'customer_name') String? customerName,

    /// Computed by the view so the list can sort on it server-side.
    @JsonKey(name: 'due_soon') @Default(false) bool dueSoon,
    @Default(false) bool overdue,

    /// The holder of the active stage — an internal user, a partner, or neither.
    @JsonKey(name: 'assigned_to') String? assignedTo,
    @JsonKey(name: 'assignee_name') String? assigneeName,
    @JsonKey(name: 'assigned_partner') String? assignedPartner,
    @JsonKey(name: 'partner_name') String? partnerName,

    /// Grand total of the newest approved quote, in minor units. Null until a quote is
    /// approved — an unpriced job must show nothing, not zero.
    @JsonKey(name: 'quote_total') int? quoteTotalMinor,

    /// "Caster delayed on DH-2026-01048" — unresolved `job_exceptions`.
    @JsonKey(name: 'open_exceptions') @Default(0) int openExceptions,
  }) = _JobListItem;

  factory JobListItem.fromJson(Map<String, dynamic> json) => _$JobListItemFromJson(json);

  String get displayTitle {
    final t = title?.trim();
    return t == null || t.isEmpty ? displayCode : t;
  }

  bool get isDraft => code == null;

  /// D-004: minor units plus the row's currency, surfaced as one value.
  Money? get quoteTotal =>
      quoteTotalMinor == null ? null : Money(quoteTotalMinor!, currency);

  /// See [Job.timeInStage] for why this is not read from the view's interval column.
  Duration? get timeInStage {
    final since = stageEnteredAt;
    return since == null ? null : DateTime.now().toUtc().difference(since.toUtc());
  }

  /// "1d in stage" / "4h in stage" — the mockup's dwell chip.
  String get dwellLabel {
    final d = timeInStage;
    if (d == null) return '—';
    if (d.inDays >= 1) return '${d.inDays}d in stage';
    if (d.inHours >= 1) return '${d.inHours}h in stage';
    return '${d.inMinutes}m in stage';
  }

  bool get isBlocked => openExceptions > 0;

  /// Who to chase. A partner name wins because an external delay needs a phone call, not a
  /// nudge on the shop floor.
  String? get holderName => partnerName ?? assigneeName;

  bool get isWithPartner => assignedPartner != null;
}

DateTime get _today {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
