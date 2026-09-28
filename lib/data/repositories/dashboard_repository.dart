/// Typed data access for the command centre: the eight stage counters, the production board, the
/// action queue and the at-risk figures.
///
/// `manufacturer_dashboard` was the most dishonest screen in the corpus. Its eight counters were
/// hardcoded numbers, its "3 At Risk" was a literal, its Action Queue was a static list, and its
/// board drew three of the eight columns. Every figure here is read from a view instead:
///
///  * `v_stage_counters` — D-002's eight operational counters, derived from the 14-stage rail
///    rather than from a second enum. Their sum is Total Active *by construction*, which is why
///    [StageCounters.totalActive] adds the tiles up instead of running a ninth query that could
///    disagree with them.
///  * `v_production_board` — all eight columns, grouped here by `column_stage`.
///  * `action_items` — the queue, generated from real job state.
///  * `v_job_list` — the risk figures, counted server-side with `HEAD` requests so a dashboard
///    tile never pulls two hundred rows to print one number.
///
/// The row types below are hand-written projections rather than freezed models. They belong to
/// this repository, not to the domain: a view row is a query result with no identity and nothing
/// writes one back. `shell/top_bar.dart`'s `OpenAction` established the same pattern. Enums still
/// cross the wire through `parse` (convention 6) — that rule is about the wire, not about who
/// generated the class.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'dashboard_repository.g.dart';

// ---------------------------------------------------------------- stage counters

/// One tile: a stage and how many jobs are sitting in it.
final class StageCounter {
  const StageCounter({required this.stage, required this.jobCount});

  final LifecycleStage stage;
  final int jobCount;

  bool get isEmpty => jobCount == 0;

  /// 'CAD · 12'.
  String get label => '${stage.label} · $jobCount';
}

/// D-002's eight counters, in rail order.
///
/// A stage with no jobs is still a tile, carrying zero. The mockup's row had no empty state, so a
/// quiet Monday would have silently shortened it — and an operator reading a shorter row cannot
/// tell "nothing at casting" from "casting is missing".
final class StageCounters {
  const StageCounters._(this._counts);

  factory StageCounters.fromRows(List<Map<String, dynamic>> rows) {
    final counts = <LifecycleStage, int>{};
    for (final row in rows) {
      // A stage this build does not know means the database is ahead of the app. Skipping the row
      // is right: an unknown counter has nowhere to render, and crashing the whole dashboard over
      // it would be worse than being one tile short.
      final stage = LifecycleStage.parse(row['stage'] as String?);
      if (stage == null) continue;
      counts[stage] = (row['job_count'] as int?) ?? 0;
    }
    return StageCounters._(Map<LifecycleStage, int>.unmodifiable(counts));
  }

  static const empty = StageCounters._(<LifecycleStage, int>{});

  final Map<LifecycleStage, int> _counts;

  int countFor(LifecycleStage stage) => _counts[stage] ?? 0;

  /// The eight tiles, always all eight, in rail order.
  List<StageCounter> get tiles => [
        for (final stage in LifecycleStage.operational)
          StageCounter(stage: stage, jobCount: countFor(stage)),
      ];

  /// "Total Active". D-002: the eight counters summed to exactly 55 in the mockup, which is the
  /// evidence they are the in-production subset of the 14 — so the total is their sum and not a
  /// separate query that could contradict them.
  int get totalActive {
    var total = 0;
    for (final stage in LifecycleStage.operational) {
      total += countFor(stage);
    }
    return total;
  }

  bool get isEmpty => totalActive == 0;

  /// The busiest stage — where a production manager should look first. Null when nothing is
  /// active at all.
  StageCounter? get busiest {
    StageCounter? worst;
    for (final tile in tiles) {
      if (tile.jobCount == 0) continue;
      if (worst == null || tile.jobCount > worst.jobCount) worst = tile;
    }
    return worst;
  }
}

// ---------------------------------------------------------------- board

/// One card on the production board, from `v_production_board`.
final class BoardCard {
  const BoardCard({
    required this.jobId,
    required this.columnStage,
    required this.displayCode,
    required this.priority,
    this.title,
    this.customerName,
    this.requestedDelivery,
    this.enteredAt,
    this.daysInStage,
    this.assigneeName,
    this.partnerName,
  });

  /// Returns null for a row whose stage this build does not recognise, so the caller can drop it
  /// rather than invent a column for it.
  static BoardCard? fromRow(Map<String, dynamic> row) {
    final stage = LifecycleStage.parse(row['column_stage'] as String?);
    if (stage == null) return null;
    return BoardCard(
      jobId: row['job_id'] as String,
      columnStage: stage,
      // `coalesce(code, draft_code)` is resolved in SQL, so this is never empty (D-001).
      displayCode: row['display_code'] as String,
      priority: Priority.parse(row['priority'] as String?) ?? Priority.standard,
      title: row['title'] as String?,
      customerName: row['customer_name'] as String?,
      requestedDelivery: _parseDate(row['requested_delivery']),
      enteredAt: _parseTimestamp(row['entered_at']),
      daysInStage: (row['days_in_stage'] as num?)?.toInt(),
      assigneeName: row['assignee_name'] as String?,
      partnerName: row['partner_name'] as String?,
    );
  }

  final String jobId;
  final LifecycleStage columnStage;

  /// 'DH-2026-01842' or 'DRAFT-992A'.
  final String displayCode;
  final Priority priority;
  final String? title;
  final String? customerName;
  final DateTime? requestedDelivery;
  final DateTime? enteredAt;

  /// From the view's own `extract(day from now() - entered_at)`.
  final int? daysInStage;

  final String? assigneeName;
  final String? partnerName;

  /// A card must always say something specific, so it falls back to the code.
  String get displayTitle {
    final text = title?.trim();
    return text == null || text.isEmpty ? displayCode : text;
  }

  /// Who to chase. A partner wins, because an external delay needs a phone call rather than a
  /// nudge across the bench.
  String? get holderName => partnerName ?? assigneeName;

  bool get isWithPartner => partnerName != null;

  /// Nobody has it. The mockup's board had no such state, so an unclaimed job looked identical to
  /// a claimed one.
  bool get isUnassigned => assigneeName == null && partnerName == null;

  bool get overdue {
    final due = requestedDelivery;
    if (due == null) return false;
    final today = DateTime.now();
    return DateTime(due.year, due.month, due.day)
        .isBefore(DateTime(today.year, today.month, today.day));
  }

  /// '3d in stage' — the dwell figure the mockup drew as static text.
  String get dwellLabel {
    final days = daysInStage;
    if (days != null) return days == 0 ? 'today' : '${days}d in stage';
    final since = enteredAt;
    if (since == null) return '—';
    final elapsed = DateTime.now().toUtc().difference(since.toUtc());
    if (elapsed.inHours >= 1) return '${elapsed.inHours}h in stage';
    return '${elapsed.inMinutes}m in stage';
  }
}

/// The board: eight columns, each with its cards.
///
/// Grouped in Dart rather than with eight queries, because `v_production_board` already returns
/// exactly the eight operational stages and one round trip beats eight on shop-floor wifi.
final class ProductionBoard {
  const ProductionBoard._(this._byStage);

  factory ProductionBoard.fromRows(List<Map<String, dynamic>> rows) {
    final grouped = <LifecycleStage, List<BoardCard>>{};
    for (final row in rows) {
      final card = BoardCard.fromRow(row);
      if (card == null) continue;
      grouped.putIfAbsent(card.columnStage, () => <BoardCard>[]).add(card);
    }
    return ProductionBoard._(grouped);
  }

  static const empty = ProductionBoard._(<LifecycleStage, List<BoardCard>>{});

  final Map<LifecycleStage, List<BoardCard>> _byStage;

  /// Always all eight, in rail order (D-002). An empty column is information — the mockup drew
  /// three columns and left the operator to guess what happened to the rest.
  List<LifecycleStage> get columns => LifecycleStage.operational;

  List<BoardCard> cardsIn(LifecycleStage stage) =>
      _byStage[stage] ?? const <BoardCard>[];

  int countIn(LifecycleStage stage) => cardsIn(stage).length;

  int get total {
    var count = 0;
    for (final stage in columns) {
      count += countIn(stage);
    }
    return count;
  }

  bool get isEmpty => total == 0;

  /// Every card, in column order — for the phone layout, which scrolls one list rather than eight.
  List<BoardCard> get allCards => [
        for (final stage in columns) ...cardsIn(stage),
      ];
}

// ---------------------------------------------------------------- action queue

/// One row of `action_items`: "Caster delayed on DH-2026-01048" → Follow Up.
///
/// In the mockup this was a hardcoded list with a decorative button. Here the destination is a
/// real route written by whoever raised the item.
final class ActionItem {
  const ActionItem({
    required this.id,
    required this.label,
    required this.severity,
    required this.createdAt,
    this.jobId,
    this.ctaLabel,
    this.ctaRoute,
    this.assignedTo,
    this.resolvedAt,
  });

  factory ActionItem.fromRow(Map<String, dynamic> row) => ActionItem(
        id: row['id'] as String,
        label: row['label'] as String,
        severity: ActionSeverity.parse(row['severity'] as String?) ?? ActionSeverity.info,
        createdAt: _parseTimestamp(row['created_at']) ?? DateTime.now().toUtc(),
        jobId: row['job_id'] as String?,
        ctaLabel: row['cta_label'] as String?,
        ctaRoute: row['cta_route'] as String?,
        assignedTo: row['assigned_to'] as String?,
        resolvedAt: _parseTimestamp(row['resolved_at']),
      );

  final String id;
  final String label;
  final ActionSeverity severity;
  final DateTime createdAt;
  final String? jobId;
  final String? ctaLabel;

  /// An in-app path. Only an absolute path is followed, so a malformed row cannot send an
  /// operator somewhere strange.
  final String? ctaRoute;

  final String? assignedTo;
  final DateTime? resolvedAt;

  bool get isOpen => resolvedAt == null;

  bool get hasRoute => ctaRoute != null && ctaRoute!.startsWith('/');

  /// 'Follow Up' — falls back to something that still describes the action.
  String get actionLabel => ctaLabel ?? 'Open';

  bool get isBlocking =>
      severity == ActionSeverity.error || severity == ActionSeverity.warning;

  Duration get age => DateTime.now().toUtc().difference(createdAt.toUtc());
}

// ---------------------------------------------------------------- risk

/// The headline figures, each counted server-side.
///
/// `dueSoon` includes anything already late: `v_job_list.due_soon` is
/// `requested_delivery <= current_date + 1`, which a past date also satisfies. That is
/// deliberate — a "due within a day" tile that quietly excluded the overdue jobs would be the
/// most dangerous number on the screen.
final class RiskSummary {
  const RiskSummary({
    required this.totalActive,
    required this.dueSoon,
    required this.overdue,
    required this.blocked,
    required this.atRisk,
  });

  static const empty = RiskSummary(
    totalActive: 0,
    dueSoon: 0,
    overdue: 0,
    blocked: 0,
    atRisk: 0,
  );

  /// Jobs with status `in_production` standing at one of the eight counted stages. Should agree
  /// with [StageCounters.totalActive]; when it does not, a job is in production with no active or
  /// blocked stage row, which is a seeding fault worth seeing rather than smoothing over. Jobs at
  /// inquiry, pricing, final approval, polishing or dispatch are in production but on no tile.
  final int totalActive;

  final int dueSoon;
  final int overdue;

  /// Jobs carrying an unresolved `job_exceptions` row — "Caster delayed".
  final int blocked;

  /// "3 At Risk": past its date, or blocked by an open exception.
  ///
  /// `jobs.is_at_risk` is a manual flag that `v_job_list` does not carry, so this is the derived
  /// figure — and derived is the right kind, because the mockup's literal `3` never moved.
  final int atRisk;

  bool get isClear => atRisk == 0 && overdue == 0;
}

// ---------------------------------------------------------------- repository

final class DashboardRepository {
  const DashboardRepository(this._client, this._identity);

  final SupabaseClient _client;

  /// D-008: `org_id` and the actor come from the signed-in operator's `app_users` row and from
  /// nowhere else. A repository never invents either.
  final RepoIdentity _identity;

  /// Every dashboard query is org-scoped explicitly as well as by RLS. A view is not a policy: if
  /// one is ever created without `security_invoker`, the filter is what still keeps a second
  /// tenant's counters off this screen (D-008).
  String get _org => _identity.requireOrgId();

  String get _actor => _identity.requireUserId();

  /// Statuses a job can be in while it is still somebody's problem. Read off
  /// [JobStatus.isOpen] so the definition lives with the enum rather than as a list of strings
  /// here.
  static List<String> get _openStatuses =>
      [for (final status in JobStatus.values) if (status.isOpen) status.wire];

  // -------------------------------------------------------------- counters

  /// D-002's eight counters.
  Future<StageCounters> stageCounters() async {
    final rows = await guard(
      () => _client.from('v_stage_counters').select().eq('org_id', _org),
    );
    return StageCounters.fromRows(rows);
  }

  // -------------------------------------------------------------- board

  /// The board, ordered so the work that matters is at the top of each column: the earliest
  /// requested date first, then the longest-waiting job.
  ///
  /// `nullsFirst: false` keeps undated jobs at the bottom instead of at the front, which is what
  /// PostgREST would otherwise do for a descending sort.
  Future<ProductionBoard> productionBoard() async {
    final rows = await guard(
      () => _client
          .from('v_production_board')
          .select()
          .eq('org_id', _org)
          .order('requested_delivery', ascending: true, nullsFirst: false)
          .order('entered_at', ascending: true, nullsFirst: false),
    );
    return ProductionBoard.fromRows(rows);
  }

  // -------------------------------------------------------------- action queue

  /// The Action Queue. Severity first so an error sits above a nudge, then newest.
  Future<List<ActionItem>> actionItems({
    bool openOnly = true,
    String? jobId,
    int limit = 50,
  }) async {
    final rows = await guard(() {
      var query = _client.from('action_items').select().eq('org_id', _org);
      if (openOnly) query = query.isFilter('resolved_at', null);
      if (jobId != null) query = query.eq('job_id', jobId);
      return query.order('created_at', ascending: false).limit(limit);
    });
    final items = [for (final row in rows) ActionItem.fromRow(row)];
    // `action_severity` is declared info/warning/error/success, so ordering on the enum column in
    // SQL would sort alphabetically and put 'error' below 'info'. Sorting here uses the severity
    // order an operator actually reads: error, warning, info, success.
    items.sort((a, b) {
      final bySeverity = _severityRank(a.severity).compareTo(_severityRank(b.severity));
      return bySeverity != 0 ? bySeverity : b.createdAt.compareTo(a.createdAt);
    });
    return items;
  }

  Future<ActionItem> raiseActionItem({
    required String label,
    ActionSeverity severity = ActionSeverity.info,
    String? jobId,
    String? ctaLabel,
    String? ctaRoute,
    String? assignedTo,
  }) async {
    final text = label.trim();
    if (text.isEmpty) {
      throw const RuleViolation(
        message: 'Say what needs doing. That line is the whole item.',
        code: 'action_unlabelled',
      );
    }
    // A route that is not an absolute in-app path would produce a dead button, which is the exact
    // fault the mockup shipped.
    final route = ctaRoute?.trim();
    if (route != null && route.isNotEmpty && !route.startsWith('/')) {
      throw RuleViolation(
        message: 'The action link has to be an in-app path starting with "/". Got "$route".',
        code: 'action_bad_route',
      );
    }

    final row = await guard(
      () => _client
          .from('action_items')
          .insert(<String, dynamic>{
            'org_id': _org,
            'job_id': jobId,
            'severity': severity.wire,
            'label': text,
            'cta_label': ctaLabel?.trim(),
            'cta_route': route == null || route.isEmpty ? null : route,
            'assigned_to': assignedTo,
          })
          .select()
          .single(),
    );
    return ActionItem.fromRow(row);
  }

  Future<ActionItem> resolveActionItem(String itemId) async {
    final row = await guard(
      () => _client
          .from('action_items')
          .update(<String, dynamic>{
            'resolved_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', itemId)
          .eq('org_id', _org)
          .select()
          .single(),
    );
    return ActionItem.fromRow(row);
  }

  /// Hand an item to someone. The mockup's queue had no owner column, so "Follow Up" was
  /// everybody's job and therefore nobody's.
  Future<ActionItem> assignActionItem({
    required String itemId,
    String? userId,
  }) async {
    final row = await guard(
      () => _client
          .from('action_items')
          .update(<String, dynamic>{'assigned_to': userId ?? _actor})
          .eq('id', itemId)
          .eq('org_id', _org)
          .select()
          .single(),
    );
    return ActionItem.fromRow(row);
  }

  // -------------------------------------------------------------- risk

  /// The four headline figures, as four `HEAD` count requests issued together.
  ///
  /// Counting in Postgres rather than pulling rows is the difference between four small requests
  /// and four full job lists on a tablet at the bench. They are issued concurrently because they
  /// are independent reads, so the dashboard waits for the slowest rather than the sum.
  Future<RiskSummary> riskSummary() async {
    final open = _openStatuses;
    final results = await Future.wait<int>(<Future<int>>[
      guard(
        () => _client
            .from('v_job_list')
            .count(CountOption.exact)
            .eq('org_id', _org)
            .eq('status', JobStatus.inProduction.wire)
            .inFilter('current_stage', [for (final s in LifecycleStage.operational) s.wire]),
      ),
      guard(
        () => _client
            .from('v_job_list')
            .count(CountOption.exact)
            .eq('org_id', _org)
            .eq('due_soon', true),
      ),
      guard(
        () => _client
            .from('v_job_list')
            .count(CountOption.exact)
            .eq('org_id', _org)
            .eq('overdue', true),
      ),
      guard(
        () => _client
            .from('v_job_list')
            .count(CountOption.exact)
            .eq('org_id', _org)
            .inFilter('status', open)
            .gt('open_exceptions', 0),
      ),
      guard(
        () => _client
            .from('v_job_list')
            .count(CountOption.exact)
            .eq('org_id', _org)
            .inFilter('status', open)
            .or('overdue.is.true,open_exceptions.gt.0'),
      ),
    ]);

    return RiskSummary(
      totalActive: results[0],
      dueSoon: results[1],
      overdue: results[2],
      blocked: results[3],
      atRisk: results[4],
    );
  }

  /// The jobs behind the at-risk number.
  ///
  /// A count with nothing behind it is what the mockup shipped — "3 At Risk" was a literal with
  /// no list and no link. Overdue first, then the ones that are merely blocked.
  Future<List<JobListItem>> atRiskJobs({int limit = 25}) async {
    final rows = await guard(
      () => _client
          .from('v_job_list')
          .select()
          .eq('org_id', _org)
          .inFilter('status', _openStatuses)
          .or('overdue.is.true,open_exceptions.gt.0')
          .order('overdue', ascending: false)
          .order('requested_delivery', ascending: true, nullsFirst: false)
          .limit(limit),
    );
    return [for (final row in rows) JobListItem.fromJson(row)];
  }

  /// Everything due inside a day, overdue included — the "DUE TODAY" / "DUE TMRW" strip.
  Future<List<JobListItem>> dueSoonJobs({int limit = 25}) async {
    final rows = await guard(
      () => _client
          .from('v_job_list')
          .select()
          .eq('org_id', _org)
          .eq('due_soon', true)
          .order('requested_delivery', ascending: true, nullsFirst: false)
          .limit(limit),
    );
    return [for (final row in rows) JobListItem.fromJson(row)];
  }

  /// Read order, not alphabetical order.
  static int _severityRank(ActionSeverity severity) => switch (severity) {
        ActionSeverity.error => 0,
        ActionSeverity.warning => 1,
        ActionSeverity.info => 2,
        ActionSeverity.success => 3,
      };
}

// ---------------------------------------------------------------- row parsing

/// Convention 7: Postgres sends instants in UTC and `DateTime.parse` keeps them that way. The
/// conversion to local time happens at render, never here.
DateTime? _parseTimestamp(Object? value) {
  if (value is DateTime) return value;
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
  return null;
}

/// A `date` column is a calendar day, so it parses to a local midnight — which is what a
/// delivery date means to the person reading it.
DateTime? _parseDate(Object? value) => _parseTimestamp(value);

// ---------------------------------------------------------------- providers

@Riverpod(keepAlive: true)
DashboardRepository dashboardRepository(Ref ref) => DashboardRepository(
      ref.watch(supabaseProvider),
      ref.watch(repoIdentityProvider),
    );

/// D-002's eight counters. Their sum is Total Active.
@riverpod
Future<StageCounters> stageCounters(Ref ref) =>
    ref.watch(dashboardRepositoryProvider).stageCounters();

@riverpod
Future<ProductionBoard> productionBoard(Ref ref) =>
    ref.watch(dashboardRepositoryProvider).productionBoard();

@riverpod
Future<List<ActionItem>> actionQueue(Ref ref) =>
    ref.watch(dashboardRepositoryProvider).actionItems();

@riverpod
Future<RiskSummary> riskSummary(Ref ref) =>
    ref.watch(dashboardRepositoryProvider).riskSummary();

@riverpod
Future<List<JobListItem>> atRiskJobs(Ref ref) =>
    ref.watch(dashboardRepositoryProvider).atRiskJobs();
