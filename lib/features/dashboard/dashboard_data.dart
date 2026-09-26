/// What the command centre reads, and the one thing it computes.
///
/// `manufacturer_dashboard` was the least honest screen in the corpus: eight hardcoded counters,
/// a literal "3 At Risk" that never moved, and an Action Queue that was a static list of three
/// sentences behind a decorative "Follow Up" button. The counters and the risk figures are now
/// server-side reads (`v_stage_counters`, `v_job_list`). The queue is the piece that had no data
/// source at all, so it is **derived here from real job state** — which is the whole product
/// claim of the screen and the reason this file exists.
///
/// Four severity classes, because `action_severity` has four and an operator triages by them:
///
///  * `error`   — work is stopped or the promise is already broken: an open exception, a job past
///                its delivery date.
///  * `warning` — it breaks next: due inside a day, or a stage that has not moved in a week.
///  * `info`    — it needs an owner: an active stage with nobody on it.
///  * `success` — something cleared. Only a *raised* `action_items` row can be this; nothing about
///                a job's own state says "good news", and inventing one would be the mockup's
///                habit rather than a fix for it.
///
/// One entry per job, leading with its most severe reason and folding the rest into the detail
/// line. A queue that lists the same job four times is a queue nobody reads to the bottom of.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/data/repositories/dashboard_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/job.dart';

part 'dashboard_data.g.dart';

/// A stage that has not moved in this long is stalled.
///
/// One threshold for all eight stages is a first cut, not a claim: casting genuinely takes days
/// and CAD review should not. When `stage_sla_days` lands per stage, this constant is what it
/// replaces.
const stallAfter = Duration(days: 7);

/// The queue reads committed work only. A draft nobody has committed is not yet a promise, and
/// listing it under "overdue" would be counting an intention as a debt.
const queueScope = JobListFilter(draftScope: DraftScope.committedOnly);

/// Rush and Critical, highest priority first. Twelve is a screenful; past that the list stops
/// being a shortlist.
const priorityFilter = JobListFilter(
  priorities: {Priority.rush, Priority.critical},
  draftScope: DraftScope.committedOnly,
  sort: JobListSort.highestPriority,
  limit: 12,
);

final _dayMonth = DateFormat('d MMM');

// ================================================================= counters and risk

/// D-002's eight counters, re-read whenever the rail or a job moves.
///
/// `v_stage_counters` is a view and PostgREST cannot stream one, so the channel is a change
/// signal and the view is re-read — the pattern `liveQuery` exists for. A dashboard whose numbers
/// only move on a manual refresh is a slower version of the same lie the mockup told.
@riverpod
Stream<Live<StageCounters>> liveStageCounters(Ref ref) {
  final repo = ref.watch(dashboardRepositoryProvider);
  return liveQuery<StageCounters>(
    client: ref.watch(supabaseProvider),
    channelName: 'stage-counters',
    tables: const [LiveTable(table: 'job_stages'), LiveTable(table: 'jobs')],
    read: repo.stageCounters,
  );
}

/// The headline figures, recounted whenever the counters move.
///
/// Tying the two together is the point: Total Delayed and Total Active are read by the same eye
/// in the same glance, so they must never be two different ages. Both watches happen before the
/// await, so this stays a well-formed dependency rather than a read of a disposed provider.
@riverpod
Future<RiskSummary> dashboardRisk(Ref ref) async {
  final repo = ref.watch(dashboardRepositoryProvider);
  final counters = ref.watch(liveStageCountersProvider.future);
  await counters;
  return repo.riskSummary();
}

// ================================================================= the action queue

/// Why a job is in the queue.
///
/// Declaration order is read order — stopped work, then broken promises, then work nobody owns —
/// so sorting on [Enum.index] gives the sequence an operator wants without a second table.
enum QueueReason {
  blocked(ActionSeverity.error),
  overdue(ActionSeverity.error),
  dueSoon(ActionSeverity.warning),
  stalled(ActionSeverity.warning),
  unassigned(ActionSeverity.info);

  const QueueReason(this.severity);

  final ActionSeverity severity;
}

/// One row of the Action Queue, whether a human raised it or the job's own state did.
@immutable
final class QueueEntry {
  const QueueEntry({
    required this.id,
    required this.label,
    required this.severity,
    this.detail,
    this.route,
    this.code,
    this.jobId,
    this.actionLabel = 'Open the job',
    this.waitingSince,
    this.raisedId,
  });

  /// Stable across rebuilds so the list can key on it — `raised:<uuid>` or `job:<uuid>:<reason>`.
  final String id;

  /// The sentence. Names the job code, because that is what gets said across a bench.
  final String label;

  /// Everything else worth knowing on one line — the other reasons, the customer, the holder.
  final String? detail;

  final ActionSeverity severity;

  /// Where the row drills through to. Always an in-app path; the mockup's button went nowhere.
  final String? route;

  final String? code;
  final String? jobId;

  /// What the row's action does — 'Follow Up' from a raised item, 'Open the job' otherwise.
  final String actionLabel;

  /// Oldest first inside a severity class: whatever has been waiting longest is the thing that
  /// has been ignored longest.
  final DateTime? waitingSince;

  /// Set only for a row that exists in `action_items`, which is what can be marked done. A
  /// derived row clears when the job state behind it clears, and nothing else.
  final String? raisedId;

  bool get isRaised => raisedId != null;

  bool get hasRoute => route != null;
}

/// Raised items and derived items in one list, most severe first.
@riverpod
Future<List<QueueEntry>> dashboardQueue(Ref ref) async {
  // Both watches precede both awaits.
  final raisedFuture = ref.watch(actionQueueProvider.future);
  final jobsFuture = ref.watch(jobListProvider(queueScope).future);
  final raised = await raisedFuture;
  final jobs = await jobsFuture;

  final entries = <QueueEntry>[
    for (final item in raised) entryFromRaised(item),
    ...deriveQueueEntries(jobs),
  ]..sort(compareQueueEntries);
  return List<QueueEntry>.unmodifiable(entries);
}

/// An `action_items` row. Its `cta_route` is honoured when it is an in-app path, and it falls back
/// to the job it names rather than rendering a row that goes nowhere.
QueueEntry entryFromRaised(ActionItem item) {
  final jobId = item.jobId;
  return QueueEntry(
    id: 'raised:${item.id}',
    raisedId: item.id,
    label: item.label,
    severity: item.severity,
    route: item.hasRoute ? item.ctaRoute : (jobId == null ? null : Paths.job(jobId)),
    jobId: jobId,
    actionLabel: item.actionLabel,
    waitingSince: item.createdAt,
  );
}

/// The queue the mockup drew and never generated.
List<QueueEntry> deriveQueueEntries(List<JobListItem> jobs) {
  final out = <QueueEntry>[];
  for (final job in jobs) {
    final reasons = <QueueReason>[];

    if (job.isBlocked) reasons.add(QueueReason.blocked);
    // `v_job_list.due_soon` is `requested_delivery <= current_date + 1`, which an already-late
    // date also satisfies — so overdue wins and the two are never both reported.
    if (job.overdue) {
      reasons.add(QueueReason.overdue);
    } else if (job.dueSoon) {
      reasons.add(QueueReason.dueSoon);
    }
    final dwell = job.timeInStage;
    if (dwell != null && dwell >= stallAfter) reasons.add(QueueReason.stalled);
    // A job with no active stage row is a draft or a closed job; neither needs an owner.
    if (job.holderName == null && job.currentStage != null) {
      reasons.add(QueueReason.unassigned);
    }

    if (reasons.isEmpty) continue;
    reasons.sort((a, b) => a.index.compareTo(b.index));
    final lead = reasons.first;

    out.add(
      QueueEntry(
        id: 'job:${job.id}:${lead.name}',
        label: _labelFor(lead, job),
        detail: _detailFor(reasons.skip(1), job),
        severity: lead.severity,
        route: Paths.job(job.id),
        code: job.displayCode,
        jobId: job.id,
        actionLabel: _actionFor(lead),
        waitingSince: _waitingSince(lead, job),
      ),
    );
  }
  return out;
}

/// Read order, not alphabetical order — the same reason `DashboardRepository` sorts severity in
/// Dart rather than in SQL, where `error` would sort below `info`.
int severityRank(ActionSeverity severity) => switch (severity) {
      ActionSeverity.error => 0,
      ActionSeverity.warning => 1,
      ActionSeverity.info => 2,
      ActionSeverity.success => 3,
    };

int compareQueueEntries(QueueEntry a, QueueEntry b) {
  final bySeverity = severityRank(a.severity).compareTo(severityRank(b.severity));
  if (bySeverity != 0) return bySeverity;
  final since = a.waitingSince;
  final other = b.waitingSince;
  if (since == null && other == null) return a.label.compareTo(b.label);
  // A row with no date sorts last: it cannot claim to have been waiting longest.
  if (since == null) return 1;
  if (other == null) return -1;
  final byAge = since.compareTo(other);
  return byAge != 0 ? byAge : a.label.compareTo(b.label);
}

String _stageName(JobListItem job) => job.currentStage?.label ?? 'its current stage';

String _labelFor(QueueReason reason, JobListItem job) => switch (reason) {
      QueueReason.blocked => '${job.displayCode} is blocked by '
          '${job.openExceptions} open exception${job.openExceptions == 1 ? '' : 's'}',
      QueueReason.overdue => '${job.displayCode} is past its delivery date',
      QueueReason.dueSoon => '${job.displayCode} is due ${_dueWord(job)}',
      QueueReason.stalled =>
        '${job.displayCode} has not moved out of ${_stageName(job)} in ${_dwellDays(job)} days',
      QueueReason.unassigned => '${job.displayCode} is at ${_stageName(job)} with nobody on it',
    };

String _actionFor(QueueReason reason) => switch (reason) {
      QueueReason.blocked => 'Resolve it',
      QueueReason.overdue || QueueReason.dueSoon => 'Check the date',
      QueueReason.stalled => 'Chase it',
      QueueReason.unassigned => 'Assign it',
    };

String? _detailFor(Iterable<QueueReason> rest, JobListItem job) {
  final parts = <String>[
    for (final reason in rest) _phraseFor(reason, job),
    if (job.customerName != null) job.customerName!,
    if (job.holderName != null)
      job.isWithPartner ? 'with ${job.holderName} (partner)' : 'with ${job.holderName}',
  ]..removeWhere((part) => part.isEmpty);
  return parts.isEmpty ? null : parts.join(' · ');
}

String _phraseFor(QueueReason reason, JobListItem job) => switch (reason) {
      QueueReason.blocked => '${job.openExceptions} open exception'
          '${job.openExceptions == 1 ? '' : 's'}',
      QueueReason.overdue => '${_daysLate(job) ?? 0} days late',
      QueueReason.dueSoon => 'due ${_dueWord(job)}',
      QueueReason.stalled => '${_dwellDays(job)}d in ${_stageName(job)}',
      QueueReason.unassigned => 'no owner',
    };

/// 'today' / 'tomorrow' / '4 Mar'. The view's `requested_delivery` is a `date`, so it arrives as a
/// local midnight and needs no timezone shift.
String _dueWord(JobListItem job) {
  final due = job.requestedDelivery;
  if (due == null) return 'soon';
  final late = _daysLate(job) ?? 0;
  return switch (late) {
    0 => 'today',
    -1 => 'tomorrow',
    _ => 'on ${_dayMonth.format(due)}',
  };
}

/// Whole days the job is past its requested date; negative while it is still to come.
int? _daysLate(JobListItem job) {
  final due = job.requestedDelivery;
  if (due == null) return null;
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day)
      .difference(DateTime(due.year, due.month, due.day))
      .inDays;
}

int _dwellDays(JobListItem job) => job.timeInStage?.inDays ?? 0;

/// What the row has been waiting on. A date reason waits on the date; everything else waits on the
/// stage clock, which is what makes "longest ignored" sortable across mixed reasons.
DateTime? _waitingSince(QueueReason reason, JobListItem job) => switch (reason) {
      QueueReason.overdue || QueueReason.dueSoon => job.requestedDelivery,
      QueueReason.blocked || QueueReason.stalled || QueueReason.unassigned =>
        job.stageEnteredAt,
    };
