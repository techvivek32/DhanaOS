/// `job_stages` — the append-only transition log, and the 14-stage rail built from it.
///
/// D-005: stage is derived from this table, never from a mutable column. All 14 rows are
/// inserted at commit by `fn_seed_job_stages` so the timeline renders complete from day one,
/// with future stages `pending`.
library;

import 'package:collection/collection.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'job_stage.freezed.dart';
part 'job_stage.g.dart';

@freezed
abstract class JobStage with _$JobStage {
  const JobStage._();

  const factory JobStage({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @LifecycleStageConverter() required LifecycleStage stage,
    @StageStateConverter() @Default(StageState.pending) StageState state,

    /// 1..14, the position in the rail. `enum_range` order, so sorting on this is sorting on
    /// the canonical vocabulary (D-002).
    required int seq,
    @JsonKey(name: 'entered_at') DateTime? enteredAt,

    /// "Expected Aug 12 05:00 PM" — the promise a partner or bench was given.
    @JsonKey(name: 'expected_at') DateTime? expectedAt,
    @JsonKey(name: 'completed_at') DateTime? completedAt,

    /// Who or what closed it. The mockups credited "Completed by JD" (a person),
    /// "Completed by PR-02" (a printer) and "Completed by Forge-A" (a machine).
    @JsonKey(name: 'completed_by') String? completedBy,
    @JsonKey(name: 'resource_id') String? resourceId,
    @JsonKey(name: 'assigned_to') String? assignedTo,

    /// D-008: the only thing that puts a job on a vendor's queue.
    @JsonKey(name: 'assigned_partner') String? assignedPartner,

    /// "Caster delayed".
    @JsonKey(name: 'blocked_reason') String? blockedReason,
    String? notes,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _JobStage;

  factory JobStage.fromJson(Map<String, dynamic> json) => _$JobStageFromJson(json);

  bool get isPending => state == StageState.pending;
  bool get isActive => state == StageState.active;
  bool get isCompleted => state == StageState.completed;
  bool get isSkipped => state == StageState.skipped;
  bool get isBlocked => state == StageState.blocked;

  /// Settled either way: a skipped stage is finished business, not work in waiting.
  bool get isClosed => isCompleted || isSkipped;

  /// How long the job has sat here. Closed stages report the real span; an open stage reports
  /// the running clock, which is what the dashboard's dwell chip shows.
  Duration? get dwell {
    final start = enteredAt;
    if (start == null) return null;
    final end = completedAt ?? DateTime.now().toUtc();
    return end.toUtc().difference(start.toUtc());
  }

  /// Past its promise and still open. This, not a hardcoded badge, is what "Caster delayed"
  /// should be driven by.
  bool get isLate {
    final due = expectedAt;
    if (due == null || isClosed) return false;
    return due.toUtc().isBefore(DateTime.now().toUtc());
  }

  Duration? get overdueBy {
    final due = expectedAt;
    if (due == null || isClosed) return null;
    final late = DateTime.now().toUtc().difference(due.toUtc());
    return late.isNegative ? null : late;
  }

  /// Work that left the building. D-002: only casting and certification can.
  bool get isWithPartner => assignedPartner != null;

  bool get isUnassigned => assignedTo == null && assignedPartner == null;

  /// "1d" / "4h" / "18m" — the compact dwell the rail prints under a stage dot.
  String get dwellLabel {
    final d = dwell;
    if (d == null) return '—';
    if (d.inDays >= 1) return '${d.inDays}d';
    if (d.inHours >= 1) return '${d.inHours}h';
    return '${d.inMinutes}m';
  }
}

/// All 14 rail rows for one job, in canonical order.
///
/// D-002: the dashboard's 8 operational counters are a derived view over this rail, never a
/// second enum. Build one with [StageRail.of] and let it answer "where is this job", so no
/// screen has to re-implement the ordering.
@freezed
abstract class StageRail with _$StageRail {
  const StageRail._();

  const factory StageRail(List<JobStage> stages) = _StageRail;

  /// PostgREST makes no ordering promise, so sort by rail position rather than trusting the
  /// row order that came back.
  static StageRail of(Iterable<JobStage> rows) {
    final sorted = rows.toList()..sort((a, b) => a.seq.compareTo(b.seq));
    return StageRail(List<JobStage>.unmodifiable(sorted));
  }

  static const empty = StageRail(<JobStage>[]);

  int get length => stages.length;
  bool get isEmpty => stages.isEmpty;

  /// `fn_seed_job_stages` inserts all 14 at commit. Fewer rows means this job has not been
  /// committed yet, or the seed failed — either way the rail must not claim to be complete.
  bool get isSeeded => stages.length == LifecycleStage.values.length;

  /// Where the job is now. Blocked counts as active: the job has not left the stage, it is
  /// stuck in it.
  JobStage? get activeStage =>
      stages.firstWhereOrNull((s) => s.isActive) ??
      stages.firstWhereOrNull((s) => s.isBlocked);

  LifecycleStage? get activeLifecycle => activeStage?.stage;

  JobStage? stageFor(LifecycleStage stage) =>
      stages.firstWhereOrNull((s) => s.stage == stage);

  StageState stateOf(LifecycleStage stage) =>
      stageFor(stage)?.state ?? StageState.pending;

  bool isClosed(LifecycleStage stage) => stageFor(stage)?.isClosed ?? false;

  /// The stage the job moves to next, skipping rows already settled.
  JobStage? get nextStage {
    final current = activeStage;
    if (current == null) return stages.firstWhereOrNull((s) => s.isPending);
    return stages.firstWhereOrNull((s) => s.seq > current.seq && !s.isClosed);
  }

  JobStage? get previousCompleted =>
      stages.where((s) => s.isCompleted).sorted((a, b) => b.seq.compareTo(a.seq)).firstOrNull;

  /// Skipped stages count as settled — `cert` is skipped when no lab was chosen, and the job
  /// is no less finished for it.
  int get settledCount => stages.where((s) => s.isClosed).length;

  int get completedCount => stages.where((s) => s.isCompleted).length;

  /// 0.0 .. 1.0 over the whole 14-stage rail, not over the rows that happen to exist, so a
  /// partially seeded rail cannot read as 100%.
  double get progress {
    const total = 14; // LifecycleStage.values.length, fixed by D-002.
    return (settledCount / total).clamp(0.0, 1.0);
  }

  bool get isComplete => stateOf(LifecycleStage.delivered) == StageState.completed;

  JobStage? get blockedStage => stages.firstWhereOrNull((s) => s.isBlocked);

  bool get isBlocked => blockedStage != null;

  /// Any stage past its promise, in rail order — the honest source for "3 At Risk".
  List<JobStage> get lateStages => stages.where((s) => s.isLate).toList();

  /// D-002: the 8 stages the dashboard counts, in rail order.
  List<JobStage> get operational =>
      stages.where((s) => LifecycleStage.operational.contains(s.stage)).toList();

  /// Total time the job has spent in settled stages — the lead time earned so far.
  Duration get elapsed {
    var total = Duration.zero;
    for (final s in stages) {
      if (!s.isClosed) continue;
      final d = s.dwell;
      if (d != null) total += d;
    }
    return total;
  }
}
