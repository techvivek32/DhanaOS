/// Typed access to the job spine: `jobs`, the 14-stage `job_stages` rail, and the two RPCs that
/// move a job through it.
///
/// D-005 is the rule that shapes this file. A job has no mutable status column for its position
/// in the pipeline — `jobs.current_stage` and `jobs.stage_entered_at` are a cache maintained by
/// `trg_job_stage_cache`, so nothing here ever writes them. Stage movement goes through
/// `fn_complete_stage`; commit goes through `fn_commit_job`, which mints the D-001 code, seeds
/// all 14 rail rows and writes the audit event inside one transaction. Re-implementing any of
/// that client-side is how two devices end up disagreeing about where a job is.
///
/// The write paths this file *does* own are the ones Postgres has no procedure for: the
/// pre-commit draft, stage assignment, exceptions, and the orthogonal status changes
/// (hold / release / rework / cancel) that D-006 added because every gate in the mockups was
/// one-way. Each of those writes its own `activity_events` row, because the trigger only covers
/// stage transitions and an audit trail with holes is not an audit trail.
///
/// This file also carries the small amount of plumbing the other three repositories in this
/// folder share — [RepoIdentity], [Opt], [Live] and [liveQuery]. They sit in the spine file
/// rather than in a fifth file so `lib/data/repositories` stays exactly the four files the layer
/// is specified as.
library;

import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';

part 'job_repository.g.dart';

// ================================================================= shared plumbing

/// Who a write is attributed to, and which org it lands in.
///
/// D-008: a repository never invents an `org_id`. It comes from the signed-in operator's
/// `app_users` row and from nowhere else — the same single source `session.dart` establishes for
/// every identity the app renders.
final class RepoIdentity {
  const RepoIdentity({this.orgId, this.userId, this.displayName});

  final String? orgId;
  final String? userId;

  /// The operator's own name, written onto `thread_posts.author_label` and
  /// `activity_events.actor_label` so a feed reads without a join. Always the session user —
  /// never a literal (D-008).
  final String? displayName;

  bool get isReady => orgId != null && userId != null;

  String requireOrgId() =>
      orgId ??
      (throw const PermissionDenied(
        message: 'Your account is not attached to a workshop yet. Ask an admin to add you, '
            'then sign in again.',
        code: 'no_org',
      ));

  String requireUserId() =>
      userId ??
      (throw const PermissionDenied(
        message: 'Your session ended. Sign in again to save this.',
        code: 'no_session',
        sessionExpired: true,
      ));
}

@Riverpod(keepAlive: true)
RepoIdentity repoIdentity(Ref ref) {
  final user = ref.watch(currentUserProvider).value;
  return RepoIdentity(orgId: user?.orgId, userId: user?.id, displayName: user?.fullName);
}

/// "Leave this column alone" versus "set this column to null".
///
/// Every spec method in this layer is autosave-shaped: the wizard fires one call per field the
/// operator touches. A plain nullable parameter cannot express *clear the ring size* — null
/// there means "not supplied". [Opt] separates the two, so `Opt(14.0)` writes a value,
/// `Opt.clear()` writes SQL NULL, and omitting the argument writes nothing at all.
final class Opt<T extends Object> {
  const Opt(this.value);

  const Opt.clear() : value = null;

  final T? value;

  bool get isClear => value == null;

  @override
  bool operator ==(Object other) => other is Opt<T> && other.value == value;

  @override
  int get hashCode => Object.hash(T, value);

  @override
  String toString() => value == null ? 'Opt.clear()' : 'Opt($value)';
}

/// Add [field] to an update payload, encoding it on the way out.
///
/// Convention 6: an enum crosses the wire as `.wire`. Passing `(e) => e.wire` here is how that
/// stays true for every optional column without a switch at each call site.
void writeOpt<T extends Object>(
  Map<String, Object?> into,
  String column,
  Opt<T>? field, [
  Object? Function(T value)? encode,
]) {
  if (field == null) return;
  final value = field.value;
  into[column] = value == null ? null : (encode == null ? value : encode(value));
}

/// A Postgres `date` column. Dates are calendar days, not instants — converting to UTC first is
/// how a job requested on the 1st in Surat gets stored as the 31st.
String encodeDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

/// A Postgres `timestamptz` column. Convention 7: instants cross the wire in UTC.
String encodeInstant(DateTime value) => value.toUtc().toIso8601String();

/// A query result together with the health of the channel keeping it fresh.
///
/// `job_detail` drew a pulsing green dot labelled "Live Updates" over a hardcoded list — the dot
/// was a CSS animation with no socket behind it. Folding both into one value makes that lie
/// impossible: the pulse and the rows come off the same subscription, so the chip cannot read
/// "Live" while the list is stale.
final class Live<T> {
  const Live({required this.data, required this.status, this.revision = 0, this.failure});

  final T data;
  final LiveStatus status;

  /// How many row changes have arrived on this subscription. A feed that reports [isLive] and
  /// never increments this is the signature of a table missing from the `supabase_realtime`
  /// publication — see the note at the top of `data/supabase/realtime.dart`.
  final int revision;

  /// Set when the socket reported an error. [data] is still the last good read.
  final DhFailure? failure;

  bool get isLive => status == LiveStatus.live;

  String get pulseLabel => switch (status) {
        LiveStatus.live => 'Live',
        LiveStatus.connecting => 'Connecting…',
        LiveStatus.retrying => 'Reconnecting…',
        LiveStatus.offline => 'Offline — pull to refresh',
      };

  Live<R> map<R>(R Function(T data) transform) => Live<R>(
        data: transform(data),
        status: status,
        revision: revision,
        failure: failure,
      );
}

/// Run [read] once, then re-run it whenever a row changes on [tables].
///
/// PostgREST cannot stream a view, and every list surface in this app reads a view (`v_job_list`,
/// `v_digital_thread`) because the joins belong in SQL. So the channel is used as a change
/// signal and the view is re-read, rather than patching rows client-side — which would mean
/// re-implementing the view's joins in Dart and getting a different answer.
///
/// Changes are coalesced over [settle]: completing a stage fires an update on `job_stages`, an
/// insert on `activity_events` and an update on `jobs` within milliseconds of each other, and
/// three re-reads of a 200-row list for one event is how a shop-floor tablet gets hot.
Stream<Live<T>> liveQuery<T>({
  required SupabaseClient client,
  required String channelName,
  required List<LiveTable> tables,
  required Future<T> Function() read,
  Duration settle = const Duration(milliseconds: 350),
}) {
  late final StreamController<Live<T>> controller;
  StreamSubscription<LiveEvent>? watcher;
  Timer? settleTimer;

  var status = LiveStatus.connecting;
  var revision = 0;
  DhFailure? failure;
  var hasData = false;
  late T data;

  var reading = false;
  var dirty = false;

  void publish() {
    if (!hasData || controller.isClosed) return;
    controller.add(Live<T>(data: data, status: status, revision: revision, failure: failure));
  }

  Future<void> refresh() async {
    if (reading) {
      dirty = true;
      return;
    }
    reading = true;
    try {
      data = await read();
      hasData = true;
      publish();
    } on Object catch (error, stack) {
      if (!controller.isClosed) controller.addError(toDhFailure(error, stack), stack);
    } finally {
      reading = false;
      if (dirty && !controller.isClosed) {
        dirty = false;
        unawaited(refresh());
      }
    }
  }

  void schedule() {
    revision += 1;
    settleTimer?.cancel();
    settleTimer = Timer(settle, () => unawaited(refresh()));
  }

  controller = StreamController<Live<T>>(
    onListen: () {
      unawaited(refresh());
      watcher = watchTables(client, channelName: channelName, tables: tables).listen((event) {
        switch (event) {
          case LiveStatusChanged(status: final next, failure: final why):
            final wasDown = status != LiveStatus.live;
            status = next;
            failure = why;
            // A reconnect means rows may have moved while the socket was down.
            if (next == LiveStatus.live && wasDown && hasData) schedule();
            publish();
          case LiveRowChanged():
            schedule();
        }
      });
    },
    onCancel: () async {
      settleTimer?.cancel();
      settleTimer = null;
      await watcher?.cancel();
      watcher = null;
      if (!controller.isClosed) await controller.close();
    },
  );

  return controller.stream;
}

// ================================================================= job list filter

/// How a job list is ordered.
///
/// `v_job_list` carries no `created_at`, so "newest" is expressed as [codeDescending] — D-001
/// codes are year-scoped and zero-padded, which makes them sort correctly as text. Drafts
/// (`DRAFT-…`) group separately from committed jobs (`DH-…`), which is usually what a list wants.
enum JobListSort {
  dueSoonest('Due soonest'),
  longestInStage('Longest in stage'),
  highestPriority('Highest priority'),
  codeDescending('Newest code');

  const JobListSort(this.label);

  final String label;
}

/// Whether a list shows pre-commit drafts, committed jobs, or both.
enum DraftScope { all, draftsOnly, committedOnly }

/// The filter behind every job list, board column and queue.
///
/// Value-equal so it can key a Riverpod family: two screens asking for the same filter share one
/// subscription instead of opening two channels.
final class JobListFilter {
  const JobListFilter({
    this.statuses = const <JobStatus>{},
    this.stages = const <LifecycleStage>{},
    this.priorities = const <Priority>{},
    this.customerId,
    this.assignedTo,
    this.assignedPartner,
    this.search,
    this.openOnly = true,
    this.dueSoonOnly = false,
    this.overdueOnly = false,
    this.blockedOnly = false,
    this.draftScope = DraftScope.all,
    this.sort = JobListSort.dueSoonest,
    this.limit = 100,
    this.offset = 0,
  }) : _singleStage = null;

  /// One rail stage — a production-board column (D-002).
  const JobListFilter.stage(
    LifecycleStage stage, {
    this.sort = JobListSort.longestInStage,
    this.limit = 100,
    this.offset = 0,
  })  : statuses = const <JobStatus>{},
        stages = const <LifecycleStage>{},
        priorities = const <Priority>{},
        customerId = null,
        assignedTo = null,
        assignedPartner = null,
        search = null,
        openOnly = true,
        dueSoonOnly = false,
        overdueOnly = false,
        blockedOnly = false,
        draftScope = DraftScope.committedOnly,
        _singleStage = stage;

  /// A vendor's queue. D-008: scoped by the assignment itself, never by a chip.
  const JobListFilter.partner(
    String partnerId, {
    this.sort = JobListSort.dueSoonest,
    this.limit = 100,
    this.offset = 0,
  })  : statuses = const <JobStatus>{},
        stages = const <LifecycleStage>{},
        priorities = const <Priority>{},
        customerId = null,
        assignedTo = null,
        assignedPartner = partnerId,
        search = null,
        openOnly = true,
        dueSoonOnly = false,
        overdueOnly = false,
        blockedOnly = false,
        draftScope = DraftScope.committedOnly,
        _singleStage = null;

  final Set<JobStatus> statuses;
  final Set<LifecycleStage> stages;
  final Set<Priority> priorities;
  final String? customerId;
  final String? assignedTo;
  final String? assignedPartner;

  /// Matched against code, title and customer name.
  final String? search;

  /// Hide completed, cancelled and archived work. On by default: a queue is about what is left
  /// to do.
  final bool openOnly;

  final bool dueSoonOnly;
  final bool overdueOnly;

  /// Jobs with an unresolved `job_exceptions` row — "Caster delayed on DH-2026-01048".
  final bool blockedOnly;

  final DraftScope draftScope;
  final JobListSort sort;
  final int limit;
  final int offset;

  final LifecycleStage? _singleStage;

  /// The stages this filter accepts, folding in the single-stage constructor.
  Set<LifecycleStage> get effectiveStages {
    final only = _singleStage;
    return only == null ? stages : {only};
  }

  JobListFilter copyWith({
    Set<JobStatus>? statuses,
    Set<LifecycleStage>? stages,
    Set<Priority>? priorities,
    String? customerId,
    String? assignedTo,
    String? assignedPartner,
    String? search,
    bool? openOnly,
    bool? dueSoonOnly,
    bool? overdueOnly,
    bool? blockedOnly,
    DraftScope? draftScope,
    JobListSort? sort,
    int? limit,
    int? offset,
  }) =>
      JobListFilter(
        statuses: statuses ?? this.statuses,
        stages: stages ?? effectiveStages,
        priorities: priorities ?? this.priorities,
        customerId: customerId ?? this.customerId,
        assignedTo: assignedTo ?? this.assignedTo,
        assignedPartner: assignedPartner ?? this.assignedPartner,
        search: search ?? this.search,
        openOnly: openOnly ?? this.openOnly,
        dueSoonOnly: dueSoonOnly ?? this.dueSoonOnly,
        overdueOnly: overdueOnly ?? this.overdueOnly,
        blockedOnly: blockedOnly ?? this.blockedOnly,
        draftScope: draftScope ?? this.draftScope,
        sort: sort ?? this.sort,
        limit: limit ?? this.limit,
        offset: offset ?? this.offset,
      );

  /// A stable channel name, so two screens on the same filter share one socket.
  String get channelKey => 'jobs:${hashCode.toRadixString(16)}';

  static const _eq = DeepCollectionEquality();

  @override
  bool operator ==(Object other) =>
      other is JobListFilter &&
      _eq.equals(other.statuses, statuses) &&
      _eq.equals(other.effectiveStages, effectiveStages) &&
      _eq.equals(other.priorities, priorities) &&
      other.customerId == customerId &&
      other.assignedTo == assignedTo &&
      other.assignedPartner == assignedPartner &&
      other.search == search &&
      other.openOnly == openOnly &&
      other.dueSoonOnly == dueSoonOnly &&
      other.overdueOnly == overdueOnly &&
      other.blockedOnly == blockedOnly &&
      other.draftScope == draftScope &&
      other.sort == sort &&
      other.limit == limit &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(
        _eq.hash(statuses),
        _eq.hash(effectiveStages),
        _eq.hash(priorities),
        customerId,
        assignedTo,
        assignedPartner,
        search,
        openOnly,
        dueSoonOnly,
        overdueOnly,
        blockedOnly,
        draftScope,
        sort,
        Object.hash(limit, offset),
      );
}

// ================================================================= read model

/// Everything a job detail screen opens with, from one round trip.
///
/// The rail is the truth about where the job is (D-005); `job.currentStage` is only the cache the
/// list view reads. When they disagree the rail wins, which is what [stage] returns.
final class JobSnapshot {
  const JobSnapshot({required this.job, required this.rail, required this.exceptions});

  final Job job;
  final StageRail rail;

  /// Every exception ever raised on the job, newest first.
  final List<JobException> exceptions;

  List<JobException> get openExceptions => [for (final e in exceptions) if (e.isOpen) e];

  JobStage? get activeStage => rail.activeStage;

  /// D-005: derived from the rail, falling back to the cache only for a job whose rail has not
  /// been seeded yet — that is, a draft.
  LifecycleStage? get stage => rail.activeLifecycle ?? job.currentStage;

  bool get isBlocked => rail.isBlocked || openExceptions.isNotEmpty;

  /// The reason to surface at the top of the screen, or null when the job is running clean.
  String? get blockReason {
    if (job.isOnHold) return job.holdReason ?? 'This job is on hold.';
    final firstOpen = openExceptions.firstOrNull;
    if (firstOpen != null) return firstOpen.title;
    return rail.blockedStage?.blockedReason;
  }
}

// ================================================================= repository

/// D-001 draft codes. Ambiguous glyphs are left out: a draft code gets read aloud across a
/// bench, and `DRAFT-0O1I` is not a code anyone can repeat back.
const _draftAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

/// Everything `v_job_list` exposes, named rather than `*` so a view column added later cannot
/// quietly change what a 200-row list costs to fetch. `time_in_stage` is deliberately omitted:
/// PostgREST renders a Postgres interval as prose ("1 day 04:05:06") and the model computes
/// dwell from `stage_entered_at` instead.
/// A uuid no row carries, used to express "match nothing" without sending an empty `IN` list.
const _impossibleId = '00000000-0000-0000-0000-000000000000';

const _jobListColumns = 'id, org_id, display_code, code, draft_code, title, status, priority, '
    'current_stage, stage_entered_at, quantity, requested_delivery, promised_delivery, '
    'currency, customer_id, customer_name, due_soon, overdue, assigned_to, assignee_name, '
    'assigned_partner, partner_name, quote_total, open_exceptions';

final class JobRepository {
  JobRepository(this._client, this._identity);

  final SupabaseClient _client;
  final RepoIdentity _identity;

  final Random _random = Random.secure();

  // ---------------------------------------------------------------- list

  /// The job list, re-read whenever a job or a rail row moves.
  ///
  /// `jobs` and `job_stages` cover every column the view derives: [raiseException] flips the
  /// stage to `blocked` as well as inserting the exception, and a quote approval touches
  /// `jobs.updated_at`.
  Stream<Live<List<JobListItem>>> watchJobListLive([
    JobListFilter filter = const JobListFilter(),
  ]) =>
      liveQuery<List<JobListItem>>(
        client: _client,
        channelName: filter.channelKey,
        tables: const [LiveTable(table: 'jobs'), LiveTable(table: 'job_stages')],
        read: () => fetchJobList(filter),
      );

  /// [watchJobListLive] without the connection status, for a list that has no pulse chip.
  Stream<List<JobListItem>> watchJobList([JobListFilter filter = const JobListFilter()]) =>
      watchJobListLive(filter).map((live) => live.data);

  Future<List<JobListItem>> fetchJobList([JobListFilter filter = const JobListFilter()]) async {
    final rows = await guard(() => _applyOrder(_applyFilter(filter), filter));
    return [for (final row in rows) JobListItem.fromJson(row)];
  }

  PostgrestFilterBuilder<List<Map<String, dynamic>>> _applyFilter(JobListFilter filter) {
    var query = _client.from('v_job_list').select(_jobListColumns);

    // openOnly and an explicit status set intersect rather than fight: asking for
    // "cancelled, open only" is a contradiction that must return nothing, not everything.
    final wanted = <JobStatus>{
      ...(filter.statuses.isEmpty ? JobStatus.values : filter.statuses),
    }..removeWhere((s) => filter.openOnly && !s.isOpen);

    if (wanted.isEmpty) {
      // An empty IN list is a Postgres syntax error, not an empty result. Match an id that
      // cannot exist instead, so a contradictory filter returns an empty list.
      return query.eq('id', _impossibleId);
    }
    if (wanted.length != JobStatus.values.length) {
      query = query.inFilter('status', [for (final s in wanted) s.wire]);
    }

    final stages = filter.effectiveStages;
    if (stages.isNotEmpty) {
      query = query.inFilter('current_stage', [for (final s in stages) s.wire]);
    }

    if (filter.priorities.isNotEmpty) {
      query = query.inFilter('priority', [for (final p in filter.priorities) p.wire]);
    }

    final customerId = filter.customerId;
    if (customerId != null) query = query.eq('customer_id', customerId);

    final assignedTo = filter.assignedTo;
    if (assignedTo != null) query = query.eq('assigned_to', assignedTo);

    final assignedPartner = filter.assignedPartner;
    if (assignedPartner != null) query = query.eq('assigned_partner', assignedPartner);

    query = switch (filter.draftScope) {
      DraftScope.all => query,
      DraftScope.draftsOnly => query.isFilter('code', null),
      DraftScope.committedOnly => query.not('code', 'is', null),
    };

    if (filter.dueSoonOnly) query = query.eq('due_soon', true);
    if (filter.overdueOnly) query = query.eq('overdue', true);
    if (filter.blockedOnly) query = query.gt('open_exceptions', 0);

    final term = _searchTerm(filter.search);
    if (term != null) {
      // display_code catches both 'DH-2026-01842' and 'DRAFT-992A' because the view coalesces
      // them into one sortable column.
      query = query.or(
        'display_code.ilike.%$term%,title.ilike.%$term%,customer_name.ilike.%$term%',
      );
    }

    return query;
  }

  PostgrestTransformBuilder<List<Map<String, dynamic>>> _applyOrder(
    PostgrestFilterBuilder<List<Map<String, dynamic>>> query,
    JobListFilter filter,
  ) {
    // Nulls last on every sort: a job with no requested date is not the most urgent thing on the
    // board, and an unentered stage has not been sitting there longest.
    final ordered = switch (filter.sort) {
      JobListSort.dueSoonest =>
        query.order('requested_delivery', ascending: true, nullsFirst: false),
      JobListSort.longestInStage =>
        query.order('stage_entered_at', ascending: true, nullsFirst: false),
      // priority_level is declared standard < rush < critical, so descending puts critical top.
      JobListSort.highestPriority => query.order('priority', ascending: false),
      JobListSort.codeDescending => query.order('display_code', ascending: false),
    };
    return ordered
        .order('display_code', ascending: true)
        .range(filter.offset, filter.offset + filter.limit - 1);
  }

  /// PostgREST's `or=` grammar is comma and parenthesis delimited, so an operator typing
  /// `Patel, 18K (rush)` would otherwise produce a syntax error rather than no results.
  static String? _searchTerm(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final safe = trimmed.replaceAll(RegExp(r'[^\w\s\-#/]'), ' ').trim();
    return safe.isEmpty ? null : safe;
  }

  // ---------------------------------------------------------------- read one

  Future<Job> getJob(String jobId) async {
    final job = await findJob(jobId);
    return job ?? (throw _jobNotFound(jobId));
  }

  Future<Job?> findJob(String jobId) async {
    final row = await guardOrNull(
      () => _client.from('jobs').select().eq('id', jobId).maybeSingle(),
    );
    return row == null ? null : Job.fromJson(row);
  }

  /// All 14 rail rows in canonical order. Empty for a draft — `fn_seed_job_stages` runs at
  /// commit, not at creation, which is why [StageRail.isSeeded] exists.
  Future<StageRail> getStageRail(String jobId) async {
    final rows = await guard(
      () =>
          _client.from('job_stages').select().eq('job_id', jobId).order('seq', ascending: true),
    );
    return StageRail.of([for (final row in rows) JobStage.fromJson(row)]);
  }

  /// Job, rail and exceptions in one round trip.
  Future<JobSnapshot> getSnapshot(String jobId) async {
    final row = await guardOrNull(
      () => _client
          .from('jobs')
          .select('*, job_stages(*), job_exceptions(*)')
          .eq('id', jobId)
          .maybeSingle(),
    );
    if (row == null) throw _jobNotFound(jobId);
    return _snapshotFrom(row);
  }

  /// [getSnapshot], kept current. One channel covers the job row, its rail, its audit trail, its
  /// thread and its files, so a screen's pulse and its contents cannot disagree.
  Stream<Live<JobSnapshot>> watchJob(String jobId) => liveQuery<JobSnapshot>(
        client: _client,
        channelName: 'job-detail:$jobId',
        tables: LiveTable.forJob(jobId),
        read: () => getSnapshot(jobId),
      );

  JobSnapshot _snapshotFrom(Map<String, dynamic> row) {
    final stageRows =
        (row['job_stages'] as List<dynamic>? ?? const <dynamic>[]).cast<Map<String, dynamic>>();
    final exceptionRows = (row['job_exceptions'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();

    final exceptions = [for (final e in exceptionRows) JobException.fromJson(e)]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return JobSnapshot(
      job: Job.fromJson(row),
      rail: StageRail.of([for (final s in stageRows) JobStage.fromJson(s)]),
      exceptions: List<JobException>.unmodifiable(exceptions),
    );
  }

  static RecordNotFound _jobNotFound(String jobId) => RecordNotFound(
        message: 'That job is no longer there, or it is not yours to see.',
        detail: 'jobs.id=$jobId',
        code: 'PGRST116',
      );

  // ---------------------------------------------------------------- draft

  /// Open a pre-commit draft.
  ///
  /// D-001: a draft carries `DRAFT-<4 char>` until [commitJob] mints the real code. The code is
  /// generated here because Postgres has a minting function only for committed jobs, where the
  /// sequence must be gapless. A collision is caught by `jobs_draft_code_uq` and retried rather
  /// than checked for first, which would race two operators starting a job at once.
  Future<Job> createDraft({
    String? customerId,
    JobType? jobType,
    ProductCategory? category,
    ProductSubStyle? subStyle,
    String? title,
    Priority priority = Priority.standard,
    String currency = 'INR',
    int quantity = 1,
  }) async {
    final orgId = _identity.requireOrgId();
    final userId = _identity.requireUserId();

    DhFailure? lastCollision;
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        final row = await guard(
          () => _client
              .from('jobs')
              .insert({
                'org_id': orgId,
                'draft_code': _newDraftCode(),
                'customer_id': customerId,
                'job_type': jobType?.wire,
                'category': category?.wire,
                'sub_style': subStyle?.wire,
                'title': title?.trim(),
                'quantity': quantity,
                'priority': priority.wire,
                'currency': currency,
                'wizard_step': 1,
                'created_by': userId,
              })
              .select()
              .single(),
        );
        return Job.fromJson(row);
      } on DuplicateRecord catch (failure) {
        lastCollision = failure;
      }
    }
    throw DuplicateRecord(
      message: 'Could not reserve a draft number. Try again in a moment.',
      detail: lastCollision?.detail,
      code: lastCollision?.code,
    );
  }

  String _newDraftCode() {
    final buffer = StringBuffer('DRAFT-');
    for (var i = 0; i < 4; i++) {
      buffer.write(_draftAlphabet[_random.nextInt(_draftAlphabet.length)]);
    }
    return buffer.toString();
  }

  /// Autosave for the job header — the columns the intake wizard owns.
  ///
  /// Deliberately absent: `status`, `current_stage`, `stage_entered_at`, `code` and `draft_code`.
  /// D-005 makes the middle three trigger-maintained and D-001 makes the codes the minting
  /// functions' business. Hold, rework and cancel have their own methods because each owes the
  /// audit trail a reason.
  Future<Job> patchJob(
    String jobId, {
    Opt<String>? customerId,
    Opt<JobType>? jobType,
    Opt<ProductCategory>? category,
    Opt<ProductSubStyle>? subStyle,
    Opt<String>? title,
    Opt<int>? quantity,
    Opt<Priority>? priority,
    Opt<DateTime>? requestedDelivery,
    Opt<DateTime>? promisedDelivery,
    Opt<bool>? hardDeadline,
    Opt<bool>? partialAllowed,
    Opt<String>? currency,
    Opt<int>? wizardStep,
    Opt<bool>? isAtRisk,
  }) async {
    final payload = <String, Object?>{};
    writeOpt(payload, 'customer_id', customerId);
    writeOpt(payload, 'job_type', jobType, (v) => v.wire);
    writeOpt(payload, 'category', category, (v) => v.wire);
    writeOpt(payload, 'sub_style', subStyle, (v) => v.wire);
    writeOpt(payload, 'title', title, (v) => v.trim());
    writeOpt(payload, 'quantity', quantity);
    writeOpt(payload, 'priority', priority, (v) => v.wire);
    writeOpt(payload, 'requested_delivery', requestedDelivery, encodeDate);
    writeOpt(payload, 'promised_delivery', promisedDelivery, encodeDate);
    writeOpt(payload, 'hard_deadline', hardDeadline);
    writeOpt(payload, 'partial_allowed', partialAllowed);
    writeOpt(payload, 'currency', currency);
    writeOpt(payload, 'wizard_step', wizardStep);
    writeOpt(payload, 'is_at_risk', isAtRisk);

    if (payload.isEmpty) return getJob(jobId);

    final row = await guard(
      () => _client.from('jobs').update(payload).eq('id', jobId).select().single(),
    );
    return Job.fromJson(row);
  }

  // ---------------------------------------------------------------- commit

  /// Commit the draft: mint the D-001 code, seed the 14-stage rail, write the audit event.
  ///
  /// All three happen inside `fn_commit_job` because they have to be one transaction — a job
  /// with a code and no rail is unworkable, and a rail with no code has nothing to print on the
  /// job bag. The function also refuses while any `approval_gates` row is still pending, and
  /// that refusal arrives here as a [RuleViolation] carrying the database's own sentence.
  ///
  /// Returns the minted code, e.g. `DH-2026-01842`.
  Future<String> commitJob(String jobId) async {
    final userId = _identity.requireUserId();
    return guard(
      () => _client.rpc<String>('fn_commit_job', params: {'p_job': jobId, 'p_user': userId}),
    );
  }

  // ---------------------------------------------------------------- stage movement

  /// Close the active stage and open the next one.
  ///
  /// D-005: this never writes `jobs.current_stage`. `fn_complete_stage` moves the rail and the
  /// trigger updates the cache and writes the audit row.
  ///
  /// Two of the four D-011 rules live inside that function and refuse here in the database's own
  /// words — "A casting photo is required before marking this stage complete", "QC cannot be
  /// authorized with 2 unchecked item(s)". The calling surface must *also* render the gate
  /// before the operator presses anything: the casting screen reads
  /// `v_partner_queue.evidence_ready`, the QC screen counts its unticked `qc_checklist_items`.
  /// The server refusal is the backstop, not the experience.
  Future<void> completeStage({
    required String jobId,
    required LifecycleStage stage,
    String? resourceId,
    String? notes,
  }) async {
    final userId = _identity.requireUserId();
    await guard(
      () => _client.rpc<dynamic>(
        'fn_complete_stage',
        params: {
          'p_job': jobId,
          // Convention 6: the enum crosses as its Postgres value, never `.name`.
          'p_stage': stage.wire,
          'p_user': userId,
          'p_resource': resourceId,
          'p_notes': notes?.trim(),
        },
      ),
    );
  }

  /// Put a stage in somebody's hands — a bench operator, or a vendor.
  ///
  /// D-002: only casting and certification leave the building, so a partner cannot be attached
  /// to any other stage. The partner's kind is checked too: a courier on a casting stage is one
  /// of the impossible combinations the mockups' flat pickers allowed.
  ///
  /// **Schema dependency.** `0009_rls.sql` ends with
  /// `revoke update on job_stages from authenticated` and a grant covering only
  /// `state, completed_at, notes, blocked_reason` — written to stop a partner reassigning a job.
  /// As it stands it also stops an internal engineer assigning one, because assignment writes
  /// `assigned_to`, `assigned_partner` and `expected_at`. The `stages_internal_update` policy
  /// already restricts those rows to internal principals, so the fix is to add the three columns
  /// to that grant (or to expose an `fn_assign_stage`). Until then the write refuses with
  /// `42501`, and the message below says what is actually missing rather than letting it read as
  /// an absent role.
  Future<JobStage> assignStage({
    required String jobId,
    required LifecycleStage stage,
    Opt<String>? assignedTo,
    Opt<String>? assignedPartner,
    Opt<DateTime>? expectedAt,
  }) async {
    final partnerId = assignedPartner?.value;
    if (partnerId != null) {
      if (!stage.isPartnerStage) {
        throw RuleViolation(
          message: '${stage.label} is in-house work. Only casting and certification can be sent '
              'to a partner.',
          code: 'stage_not_outsourced',
        );
      }
      await _assertPartnerServes(partnerId, stage);
    }

    final payload = <String, Object?>{};
    writeOpt(payload, 'assigned_to', assignedTo);
    writeOpt(payload, 'assigned_partner', assignedPartner);
    writeOpt(payload, 'expected_at', expectedAt, encodeInstant);
    if (payload.isEmpty) {
      throw const MissingRequiredField(
        message: 'Choose who this stage goes to before saving.',
        code: 'nothing_to_assign',
      );
    }

    final Map<String, dynamic> row;
    try {
      row = await guard(
        () => _client
            .from('job_stages')
            .update(payload)
            .eq('job_id', jobId)
            .eq('stage', stage.wire)
            .select()
            .single(),
      );
    } on PermissionDenied catch (failure) {
      if (failure.code != SqlState.insufficientPrivilege) rethrow;
      throw PermissionDenied(
        message: 'This build cannot save stage assignments. The database grants update on '
            'job_stages for state, completed_at, notes and blocked_reason only.',
        detail: 'Add assigned_to, assigned_partner and expected_at to the column grant at the '
            'end of 0009_rls.sql. ${failure.detail ?? ''}'.trim(),
        code: failure.code,
      );
    }

    final assigned = JobStage.fromJson(row);
    await _logEvent(
      jobId: jobId,
      kind: ActivityKind.assigned,
      stage: stage,
      summary: 'Assigned: ${stage.label}',
      detail: _assignmentDetail(assigned),
    );
    return assigned;
  }

  Future<void> _assertPartnerServes(String partnerId, LifecycleStage stage) async {
    final row = await guardOrNull(
      () => _client.from('partners').select().eq('id', partnerId).maybeSingle(),
    );
    if (row == null) {
      throw const InvalidReference(
        message: 'That partner is not on file. Add them under Partners, then assign the stage.',
        code: 'partner_missing',
      );
    }
    final partner = Partner.fromJson(row);
    if (!partner.isActive) {
      throw RuleViolation(
        message: '${partner.name} is deactivated. Re-activate them, or pick another partner.',
        code: 'partner_inactive',
      );
    }
    if (!partner.canTakeStage(stage)) {
      throw RuleViolation(
        message: '${partner.name} is a ${partner.kind.label.toLowerCase()} partner and cannot '
            'take the ${stage.label} stage.',
        code: 'partner_wrong_kind',
      );
    }
  }

  static String _assignmentDetail(JobStage stage) {
    final parts = <String>[
      if (stage.assignedPartner != null) 'Sent to a partner',
      if (stage.assignedTo != null) 'Assigned in-house',
      // A date, not an instant: the rail row holds the exact promise, this is the audit summary.
      if (stage.expectedAt != null) 'Expected ${encodeDate(stage.expectedAt!)}',
    ];
    return parts.isEmpty ? 'Assignment cleared.' : parts.join(' · ');
  }

  // ---------------------------------------------------------------- exceptions

  /// "Report Issue" — in the mockups a 50/50 peer of the happy path with no screen behind it.
  ///
  /// Raising an exception blocks the stage by default, because an issue that does not show on the
  /// board is an issue nobody acts on. The `blocked` transition is what writes the audit row:
  /// `trg_job_stage_cache` logs it, so this method does not log a second one.
  Future<JobException> raiseException({
    required String jobId,
    required LifecycleStage stage,
    required String title,
    String? detail,
    ActionSeverity severity = ActionSeverity.warning,
    String? partnerId,
    bool blockStage = true,
  }) async {
    final headline = title.trim();
    if (headline.isEmpty) {
      throw const MissingRequiredField(
        message: 'Say what the problem is before reporting it.',
        code: 'exception_title_empty',
      );
    }

    final row = await guard(
      () => _client
          .from('job_exceptions')
          .insert({
            'job_id': jobId,
            'stage': stage.wire,
            'raised_by': _identity.userId,
            'partner_id': partnerId,
            'title': headline,
            'detail': detail?.trim(),
            'severity': severity.wire,
          })
          .select()
          .single(),
    );

    if (blockStage) {
      // `state` and `blocked_reason` are inside the column grant a partner holds, so a caster can
      // block their own stage — which is the point of the button.
      await guard(
        () => _client
            .from('job_stages')
            .update({'state': StageState.blocked.wire, 'blocked_reason': headline})
            .eq('job_id', jobId)
            .eq('stage', stage.wire),
      );
    }

    return JobException.fromJson(row);
  }

  /// Close an exception. A resolution is required: `JobException.needsResolution` exists because
  /// a closed exception with no note leaves the audit trail unable to say what was done.
  Future<JobException> resolveException({
    required String exceptionId,
    required String resolution,
    bool unblockStage = true,
  }) async {
    final text = resolution.trim();
    if (text.isEmpty) {
      throw const MissingRequiredField(
        message: 'Write what was done before closing this issue.',
        code: 'resolution_empty',
      );
    }

    final row = await guard(
      () => _client
          .from('job_exceptions')
          .update({'resolved_at': encodeInstant(DateTime.now()), 'resolution': text})
          .eq('id', exceptionId)
          .select()
          .single(),
    );
    final resolved = JobException.fromJson(row);

    if (unblockStage) {
      final stillOpen = await guard(
        () => _client
            .from('job_exceptions')
            .select('id')
            .eq('job_id', resolved.jobId)
            .eq('stage', resolved.stage.wire)
            .isFilter('resolved_at', null),
      );
      // Only the last open issue on a stage releases it; two problems means still blocked.
      if (stillOpen.isEmpty) {
        await guard(
          () => _client
              .from('job_stages')
              .update({'state': StageState.active.wire, 'blocked_reason': null})
              .eq('job_id', resolved.jobId)
              .eq('stage', resolved.stage.wire),
        );
      }
    }

    return resolved;
  }

  Future<List<JobException>> listExceptions(String jobId, {bool openOnly = false}) async {
    final rows = await guard(() {
      final query = _client.from('job_exceptions').select().eq('job_id', jobId);
      final scoped = openOnly ? query.isFilter('resolved_at', null) : query;
      return scoped.order('created_at', ascending: false);
    });
    return [for (final row in rows) JobException.fromJson(row)];
  }

  // ---------------------------------------------------------------- status (D-006)

  /// D-006: `on_hold` did not exist in any mockup — every gate there was one-way. Status is
  /// orthogonal to stage, so a job holds where it stands and resumes there.
  Future<Job> holdJob(String jobId, {required String reason}) async {
    final text = reason.trim();
    if (text.isEmpty) {
      throw const MissingRequiredField(
        message: 'Give a reason for the hold — the shop floor reads it on the job.',
        code: 'hold_reason_empty',
      );
    }
    final job = await _setStatus(jobId, JobStatus.onHold, extra: {'hold_reason': text});
    await _logEvent(
      jobId: jobId,
      kind: ActivityKind.system,
      stage: job.currentStage,
      summary: 'Job placed on hold',
      detail: text,
    );
    return job;
  }

  /// Take the job off hold and put it back where it was.
  ///
  /// The restored status is derived from the rail rather than remembered, because a job can sit
  /// on hold across a commit or a first stage completion and a remembered value would be stale.
  Future<Job> releaseHold(String jobId, {String? note}) async {
    final snapshot = await getSnapshot(jobId);
    if (!snapshot.job.isOnHold) return snapshot.job;

    final job = await _setStatus(
      jobId,
      _statusAfterHold(snapshot),
      extra: {'hold_reason': null},
    );
    await _logEvent(
      jobId: jobId,
      kind: ActivityKind.system,
      stage: job.currentStage,
      summary: 'Hold lifted',
      detail: note?.trim(),
    );
    return job;
  }

  static JobStatus _statusAfterHold(JobSnapshot snapshot) {
    if (snapshot.job.isDraft) return JobStatus.draft;
    if (snapshot.rail.isComplete) return JobStatus.completed;
    final active = snapshot.rail.activeStage;
    // Anything past the inquiry row means CAD, the bench or a vendor has already started.
    final started = snapshot.rail.settledCount > 0 || (active != null && active.seq > 1);
    return started ? JobStatus.inProduction : JobStatus.approvedReady;
  }

  /// D-006: a cancellation owes a reason, the same asymmetry D-011 rule 2 applies to a CAD
  /// rejection. The rail is left exactly as it stands — the record of how far the piece got is
  /// the whole reason to keep it.
  Future<Job> cancelJob(String jobId, {required String reason}) async {
    final text = reason.trim();
    if (text.isEmpty) {
      throw const MissingRequiredField(
        message: 'Give a reason for cancelling — it goes on the permanent record.',
        code: 'cancel_reason_empty',
      );
    }
    final job = await _setStatus(
      jobId,
      JobStatus.cancelled,
      extra: {'cancel_reason': text, 'closed_at': encodeInstant(DateTime.now())},
    );
    await _logEvent(
      jobId: jobId,
      kind: ActivityKind.system,
      stage: job.currentStage,
      summary: 'Job cancelled',
      detail: text,
    );
    return job;
  }

  /// D-006: rework sends a finished piece back to the bench without erasing what happened.
  /// Re-opening the stage itself belongs to the surface that owns that stage, not here.
  Future<Job> markForRework(String jobId, {required String reason}) async {
    final text = reason.trim();
    if (text.isEmpty) {
      throw const MissingRequiredField(
        message: 'Say what has to be redone before sending this back.',
        code: 'rework_reason_empty',
      );
    }
    final job = await _setStatus(jobId, JobStatus.rework);
    await _logEvent(
      jobId: jobId,
      kind: ActivityKind.system,
      stage: job.currentStage,
      summary: 'Sent back for rework',
      detail: text,
    );
    return job;
  }

  Future<Job> _setStatus(
    String jobId,
    JobStatus status, {
    Map<String, Object?> extra = const {},
  }) async {
    final row = await guard(
      () => _client
          .from('jobs')
          .update({'status': status.wire, ...extra})
          .eq('id', jobId)
          .select()
          .single(),
    );
    return Job.fromJson(row);
  }

  // ---------------------------------------------------------------- audit

  /// D-005: every transition writes an event. Triggers cover stage movement; this covers the
  /// transitions Postgres has no procedure for. `actor_label` is the session user's own name —
  /// D-008 allows no other source for an identity that reaches a screen.
  Future<void> _logEvent({
    required String jobId,
    required ActivityKind kind,
    required String summary,
    String? detail,
    LifecycleStage? stage,
  }) =>
      guard(
        () => _client.from('activity_events').insert({
          'job_id': jobId,
          'kind': kind.wire,
          'actor_id': _identity.userId,
          'actor_label': _identity.displayName,
          'stage': stage?.wire,
          'summary': summary,
          'detail': detail,
        }),
      );
}

// ================================================================= providers

@Riverpod(keepAlive: true)
JobRepository jobRepository(Ref ref) => JobRepository(
      ref.watch(supabaseProvider),
      ref.watch(repoIdentityProvider),
    );

/// A live job list. Two screens on an equal [JobListFilter] share one subscription.
@riverpod
Stream<List<JobListItem>> jobList(Ref ref, JobListFilter filter) =>
    ref.watch(jobRepositoryProvider).watchJobList(filter);

/// The same list with the connection status attached, for a surface that shows the pulse.
@riverpod
Stream<Live<List<JobListItem>>> jobListLive(Ref ref, JobListFilter filter) =>
    ref.watch(jobRepositoryProvider).watchJobListLive(filter);

/// One job, its rail and its exceptions, kept live.
@riverpod
Stream<Live<JobSnapshot>> jobSnapshot(Ref ref, String jobId) =>
    ref.watch(jobRepositoryProvider).watchJob(jobId);

/// The rail on its own, for a timeline that does not need the rest of the job.
@riverpod
Future<StageRail> stageRail(Ref ref, String jobId) =>
    ref.watch(jobRepositoryProvider).getStageRail(jobId);
