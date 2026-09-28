/// The vendor surface's read layer.
///
/// D-008 is the whole reason this file is shaped the way it is. `caster_dashboard` scoped its
/// queue with a decorative "Assigned to Me" pill that had nothing behind it, on a screen that
/// rendered the same hardcoded identity — "Ravi S. — Manufacturing Engineer" — as the other
/// forty-five. A vendor reading another vendor's job is a business-ending defect, so the scope
/// here comes from exactly one place: `partner_users.partner_id` for the session user, reached
/// through [AppUser.partnerId]. Nothing on screen can widen it.
///
/// Postgres is the authority. `auth_can_see_job` restricts a partner principal to jobs with a
/// stage assigned to their partner row, and that holds whatever this file does. The explicit
/// `partner_id` filters below are defence in depth for one specific reason: `v_partner_queue` is
/// a view, and a view is not a policy — if it is ever created without `security_invoker` it runs
/// as its owner and RLS stops applying to it. `DashboardRepository` takes the same stance with
/// `org_id`.
///
/// Two viewers reach these screens, not one. A partner principal sees their own queue; an
/// internal engineer, production manager or logistics operator reaches the same area as a
/// *vendor desk* (`NavArea.partners`, `AreaRoles.partnerDesk`) and sees every outsourced stage in
/// the org. [PartnerQueue.viewerPartnerId] is what distinguishes them, and the internal case is
/// scoped by the org's own partner rows rather than by the view, because `v_partner_queue`
/// carries no `org_id`.
library;

import 'package:collection/collection.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/repositories/spec_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';

part 'partner_gateway.g.dart';

// ================================================================= work state

/// What is actually outstanding on one outsourced stage, derived rather than stored.
///
/// There is no `partner_status` column and there must not be one (D-005 in miniature): the state
/// is a fact about the rows that exist — whether the stage is blocked, and whether the casting
/// evidence D-011 rule 1 demands is on file.
enum PartnerWorkState {
  blocked(
    'Blocked',
    'An issue is open on this stage. The workshop closes it.',
  ),
  awaitingEvidence(
    'Needs a photo',
    'Upload a photo of the cast tree before you can mark it complete.',
  ),
  readyToClose(
    'Ready to close',
    'Everything needed is on file. Mark it complete when the work is done.',
  );

  const PartnerWorkState(this.label, this.blurb);

  final String label;
  final String blurb;
}

// ================================================================= one queue row

/// One row of `v_partner_queue`.
///
/// A hand-written projection rather than a freezed model, the same call
/// `DashboardRepository.BoardCard` makes: a view row is a query result with no identity and
/// nothing writes one back. Enums still cross the wire through `parse` (convention 6) — that
/// rule is about the wire, not about who generated the class.
///
/// Note what the view deliberately does **not** carry: no customer name, no money, no delivery
/// date. A caster needs the alloy, the temperatures and their own promised date; the retailer's
/// identity and the job's value are not theirs to see.
final class PartnerQueueRow {
  const PartnerQueueRow({
    required this.partnerId,
    required this.jobId,
    required this.displayCode,
    required this.stage,
    required this.state,
    required this.priority,
    required this.evidenceReady,
    this.title,
    this.enteredAt,
    this.expectedAt,
    this.isLate = false,
    this.alloy,
    this.flaskTempC,
    this.metalTempC,
    this.photoId,
  });

  /// Returns null for a row whose stage or partner this build cannot resolve, so the caller drops
  /// it rather than rendering a queue entry nobody can act on. A stage the app has never heard of
  /// means the database is ahead of the build; one short row beats a crashed queue.
  static PartnerQueueRow? fromRow(Map<String, dynamic> row) {
    final stage = LifecycleStage.parse(row['stage'] as String?);
    final partnerId = row['partner_id'] as String?;
    final jobId = row['job_id'] as String?;
    if (stage == null || partnerId == null || jobId == null) return null;
    return PartnerQueueRow(
      partnerId: partnerId,
      jobId: jobId,
      // `coalesce(code, draft_code)` is resolved in SQL, so this is never empty (D-001).
      displayCode: row['display_code'] as String? ?? '—',
      stage: stage,
      state: StageState.parse(row['state'] as String?) ?? StageState.active,
      priority: Priority.parse(row['priority'] as String?) ?? Priority.standard,
      evidenceReady: row['evidence_ready'] as bool? ?? false,
      title: row['title'] as String?,
      enteredAt: _instant(row['entered_at']),
      expectedAt: _instant(row['expected_at']),
      isLate: row['is_late'] as bool? ?? false,
      alloy: row['alloy'] as String?,
      flaskTempC: (row['flask_temp_c'] as num?)?.toInt(),
      metalTempC: (row['metal_temp_c'] as num?)?.toInt(),
      photoId: row['photo_id'] as String?,
    );
  }

  /// D-008: the only thing that puts this job on a vendor's queue.
  final String partnerId;

  final String jobId;

  /// 'DH-2026-01842'.
  final String displayCode;

  /// D-002 allows only `casting` and `cert` to leave the building.
  final LifecycleStage stage;

  final StageState state;
  final Priority priority;

  /// `v_partner_queue.evidence_ready` — D-011 rule 1 read straight off the view, which is what
  /// `JobRepository.completeStage` documents the casting surface should bind to.
  final bool evidenceReady;

  final String? title;
  final DateTime? enteredAt;

  /// 'Expected Aug 12 05:00 PM' — the promise this vendor was given, not the customer's date.
  final DateTime? expectedAt;

  /// Computed by the view, so a late job is late by the server's clock and not by the tablet's.
  final bool isLate;

  final String? alloy;
  final int? flaskTempC;

  /// The hazardous figure. `caster_dashboard` rendered it as the critical value on the card.
  final int? metalTempC;

  final String? photoId;

  /// A row must always say something specific, so it falls back to the code.
  String get displayTitle {
    final text = title?.trim();
    return text == null || text.isEmpty ? displayCode : text;
  }

  bool get isBlocked => state == StageState.blocked;

  /// D-011 rule 1 applies to casting alone — `fn_complete_stage` checks `casting_params.photo_id`
  /// only for that stage, so a gem lab closing `cert` is not held behind a photo it has no reason
  /// to take.
  bool get needsCastingEvidence => stage == LifecycleStage.casting && !evidenceReady;

  PartnerWorkState get workState {
    if (isBlocked) return PartnerWorkState.blocked;
    return needsCastingEvidence
        ? PartnerWorkState.awaitingEvidence
        : PartnerWorkState.readyToClose;
  }

  /// How long this vendor has had the job.
  Duration? get dwell {
    final since = enteredAt;
    return since == null ? null : DateTime.now().toUtc().difference(since.toUtc());
  }

  /// '3d with you' — the dwell figure `caster_dashboard` drew as static text.
  String get dwellLabel {
    final elapsed = dwell;
    if (elapsed == null) return 'Not started';
    if (elapsed.inDays >= 1) return '${elapsed.inDays}d with you';
    if (elapsed.inHours >= 1) return '${elapsed.inHours}h with you';
    return '${elapsed.inMinutes}m with you';
  }

  /// How far past the promise, or null when it is not late.
  Duration? get overdueBy {
    final due = expectedAt;
    if (due == null || !isLate) return null;
    final late = DateTime.now().toUtc().difference(due.toUtc());
    return late.isNegative ? null : late;
  }

  /// '2d late' / '5h late'.
  String? get lateLabel {
    final late = overdueBy;
    if (late == null) return null;
    if (late.inDays >= 1) return '${late.inDays}d late';
    if (late.inHours >= 1) return '${late.inHours}h late';
    return '${late.inMinutes}m late';
  }

  /// '650 °C flask · 1020 °C metal' — the two numbers a caster actually sets.
  String get tempLabel {
    final parts = <String>[
      if (flaskTempC != null) '$flaskTempC °C flask',
      if (metalTempC != null) '$metalTempC °C metal',
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }
}

// ================================================================= the queue

/// Which slice of the queue is on screen.
enum PartnerQueueScope {
  open('Open'),
  needsEvidence('Needs a photo'),
  // Named `overdue` rather than `late`: `late` is a built-in identifier in Dart and cannot be an
  // enum member. The word an operator reads is still "Late".
  overdue('Late'),
  blocked('Blocked');

  const PartnerQueueScope(this.label);

  final String label;
}

/// Every outsourced stage this viewer is entitled to, with the vendor names resolved.
final class PartnerQueue {
  const PartnerQueue({
    required this.rows,
    required this.partners,
    required this.viewerPartnerId,
  });

  static const empty = PartnerQueue(
    rows: <PartnerQueueRow>[],
    partners: <String, Partner>{},
    viewerPartnerId: null,
  );

  /// Ordered by the gateway: late first, then the earliest promise.
  final List<PartnerQueueRow> rows;

  /// The `partners` rows behind [rows], keyed by id. D-008: every name on screen came off a row.
  final Map<String, Partner> partners;

  /// The session user's own partner, or null when an internal operator is looking at the vendor
  /// desk. This is `partner_users.partner_id`, never a chip on the screen.
  final String? viewerPartnerId;

  /// True when the viewer is the vendor themselves rather than the workshop.
  bool get isVendorView => viewerPartnerId != null;

  Partner? partnerFor(String id) => partners[id];

  /// The vendor's name, or the em dash — never a plausible invention.
  String nameFor(String id) => partners[id]?.name ?? '—';

  List<PartnerQueueRow> forScope(PartnerQueueScope scope) => switch (scope) {
        PartnerQueueScope.open => rows,
        PartnerQueueScope.needsEvidence =>
          [for (final row in rows) if (row.needsCastingEvidence && !row.isBlocked) row],
        PartnerQueueScope.overdue => [for (final row in rows) if (row.isLate) row],
        PartnerQueueScope.blocked => [for (final row in rows) if (row.isBlocked) row],
      };

  int countIn(PartnerQueueScope scope) => forScope(scope).length;

  int get lateCount => countIn(PartnerQueueScope.overdue);
  int get blockedCount => countIn(PartnerQueueScope.blocked);
  int get needsEvidenceCount => countIn(PartnerQueueScope.needsEvidence);

  int get readyCount =>
      [for (final row in rows) if (row.workState == PartnerWorkState.readyToClose) row].length;

  bool get isEmpty => rows.isEmpty;

  /// How many stages each vendor is holding — the figure the workshop's desk opens with, and the
  /// only honest answer to "who is the bottleneck".
  Map<String, int> get loadByPartner {
    final out = <String, int>{};
    for (final row in rows) {
      out[row.partnerId] = (out[row.partnerId] ?? 0) + 1;
    }
    return out;
  }
}

// ================================================================= one job brief

/// Everything the casting screen renders, in one bundle.
///
/// Composed here rather than as more methods on `ProductionRepository` for the reason
/// `CadGateway` gives: that repository is per-table and deliberately thin, while this screen is
/// per-decision. A caster about to close a stage needs the brief, the rail, the reference
/// imagery, the evidence and the open issues — and a screen that renders four of those five is
/// showing a half-truth about work that is about to be signed off.
final class PartnerJobBrief {
  const PartnerJobBrief({
    required this.job,
    required this.rail,
    required this.stage,
    required this.viewerPartnerId,
    required this.references,
    required this.referenceUrls,
    required this.exceptions,
    this.partner,
    this.casting,
    this.metal,
    this.evidence,
    this.evidenceUrl,
  });

  final Job job;

  /// D-005: where the job actually is. This screen closes a stage, so the rail — never
  /// `jobs.current_stage` — decides which one.
  final StageRail rail;

  /// The rail row assigned to this vendor. There is always one, or the brief would not load.
  final JobStage stage;

  /// The session user's own partner id, or null for an internal operator at the vendor desk.
  final String? viewerPartnerId;

  final Partner? partner;

  /// `casting_params`. Null until the workshop has written the brief — which is a real state: a
  /// tree can arrive before the paperwork does.
  final CastingParams? casting;

  /// The binding metal spec. `order_details` rendered the target weight in gold as the one spec
  /// that governs the bench, then made it read-only with no way to record the actual.
  final MetalSpec? metal;

  /// What the vendor works from: CAD renders, the mesh, the intake sketches. Newest first.
  final List<Attachment> references;

  /// Short-lived signed URLs for the images among them, keyed by attachment id. Signed, never
  /// public — a public URL outlives the session, the job and the customer relationship.
  final Map<String, String> referenceUrls;

  /// The casting photo already on file, if there is one (D-011 rule 1).
  final Attachment? evidence;

  final String? evidenceUrl;

  /// Every issue raised on this stage, newest first.
  final List<JobException> exceptions;

  List<JobException> get openExceptions => [for (final e in exceptions) if (e.isOpen) e];

  bool get isVendorView => viewerPartnerId != null;

  /// The mesh a caster actually needs. A render is a picture; you cannot grow a tree from it.
  Attachment? get model => references.firstWhereOrNull((file) => file.isModel);

  List<Attachment> get images => [for (final file in references) if (file.isImage) file];

  String? urlFor(Attachment file) => referenceUrls[file.id];

  /// D-011 rule 1 applies to casting alone. `fn_complete_stage` checks
  /// `casting_params.photo_id` for that stage and nothing else.
  bool get needsCastingEvidence =>
      stage.stage == LifecycleStage.casting && evidence == null;

  /// Already closed by somebody. Completing again would walk the job forward twice.
  bool get isClosed => stage.isClosed;

  /// **D-011 rule 1 — the single best idea in the corpus.** `caster_dashboard` shipped "Mark
  /// Complete" DISABLED behind a mandatory `accept="image/*"` upload, helper "Required before
  /// marking complete". This getter is what holds the button shut; `fn_complete_stage` is what
  /// holds the data shut, so the rule survives a rewrite of this screen.
  bool get canComplete => !isClosed && !needsCastingEvidence;

  /// Why the button is shut, phrased for the caster who is looking at it. Null when it is open.
  String? get completeBlockedReason {
    if (isClosed) {
      return '${stage.stage.label} is already closed. Nothing more is needed from you.';
    }
    if (needsCastingEvidence) {
      // The exact helper the mockup carried, kept word for word.
      return 'Required before marking complete';
    }
    return null;
  }

  /// A blocked stage does not stop completion — a caster whose delay is over must not wait for
  /// the workshop to close a ticket before they can hand the tree back. It does mean the confirm
  /// dialog has to say the issue is still open, which is what this sentence is for.
  String? get openIssueWarning {
    final open = openExceptions;
    if (open.isEmpty) return null;
    final first = open.first;
    return open.length == 1
        ? 'The issue "${first.title}" is still open. The workshop closes it, not you — '
            'completing the stage does not clear it.'
        : '${open.length} issues are still open on this stage, starting with '
            '"${first.title}". The workshop closes them, not you.';
  }

  /// '18K Yellow Gold' — the workshop's instruction, preferring the casting brief over the spec
  /// because the brief is what the caster was actually told to pour.
  String get alloyLabel {
    final fromBrief = casting?.alloy?.trim();
    if (fromBrief != null && fromBrief.isNotEmpty) return fromBrief;
    return metal?.alloyLabel ?? '—';
  }

  /// '8.5 g ± 0.5 g' — the binding weight, quoted verbatim from the spec.
  String get targetWeightLabel => metal?.weightLabel ?? '—';

  /// The vendor's own promise, falling back to the rail row. Never the customer's date.
  DateTime? get expectedAt => casting?.expectedAt ?? stage.expectedAt;

  DateTime? get receivedAt => casting?.receivedAt ?? stage.enteredAt;

  bool get isLate {
    final due = expectedAt;
    if (due == null || isClosed) return false;
    return due.toUtc().isBefore(DateTime.now().toUtc());
  }

  // The 14 rail nodes are NOT built here. `StageNode` is a widget-layer value type from
  // `shared/widgets/stage_rail.dart`, and a bundle that returned one would make this read layer
  // depend on the component set. `casting_job.dart` maps `rail` to nodes in one expression, which
  // is exactly what `StageNode`'s own doc comment shows.
}

// ================================================================= gateway

final class PartnerGateway {
  const PartnerGateway(this._client, this._store, this._jobs, this._production, this._specs);

  final SupabaseClient _client;
  final AttachmentStore _store;
  final JobRepository _jobs;
  final ProductionRepository _production;
  final SpecRepository _specs;

  /// Named rather than `*` so a column added to the view later cannot quietly change what a
  /// queue costs to fetch.
  static const _queueColumns = 'partner_id, job_id, display_code, title, priority, stage, '
      'state, entered_at, expected_at, is_late, alloy, flask_temp_c, metal_temp_c, photo_id, '
      'evidence_ready';

  /// What a vendor works from. Deliberately not every kind on the job: QC evidence and stone
  /// photography live in the `vault` bucket and are not a caster's business, and an invoice is
  /// certainly not.
  static const referenceKinds = <AttachmentKind>[
    AttachmentKind.cadRender,
    AttachmentKind.stl,
    AttachmentKind.cadFile,
    AttachmentKind.referenceImage,
    AttachmentKind.sketch,
  ];

  // -------------------------------------------------------------- the queue

  /// The queue for one viewer.
  ///
  /// [viewerPartnerId] non-null is a vendor looking at their own work: one `partner_id` filter,
  /// which is the row `partner_users` gave us and the only scope that exists. Null is an
  /// internal operator at the vendor desk, and that case is scoped by the org's own `partners`
  /// rows — `v_partner_queue` carries no `org_id`, so without that a second tenant's outsourced
  /// stages could reach this screen if the view were ever created without `security_invoker`.
  Future<PartnerQueue> queue({String? viewerPartnerId}) async {
    final scope = await _scope(viewerPartnerId);
    if (scope.ids.isEmpty) {
      return PartnerQueue(
        rows: const <PartnerQueueRow>[],
        partners: const <String, Partner>{},
        viewerPartnerId: viewerPartnerId,
      );
    }

    final rows = await guard(
      () => _client
          .from('v_partner_queue')
          .select(_queueColumns)
          .inFilter('partner_id', scope.ids.toList())
          // Late work first, then the earliest promise. A queue sorted by anything else makes the
          // vendor decide what is urgent, which is the workshop's call.
          .order('is_late', ascending: false)
          .order('expected_at', ascending: true, nullsFirst: false)
          .order('entered_at', ascending: true, nullsFirst: false),
    );

    final parsed = <PartnerQueueRow>[];
    for (final row in rows) {
      final item = PartnerQueueRow.fromRow(row);
      // A row for a partner outside the scope would mean the view bypassed RLS. Dropping it is
      // the safe answer; there is no correct way to render it.
      if (item == null || !scope.ids.contains(item.partnerId)) continue;
      parsed.add(item);
    }

    return PartnerQueue(
      rows: List<PartnerQueueRow>.unmodifiable(parsed),
      partners: scope.partners,
      viewerPartnerId: viewerPartnerId,
    );
  }

  /// The partner ids this viewer may see, and the rows behind them.
  ///
  /// The two halves are separate because they can legitimately disagree: `partner_users` may point
  /// at a partner whose `partners` row this session cannot read, and in that case the id is still
  /// the scope — the queue works and [PartnerQueue.nameFor] prints an em dash. Inventing a
  /// placeholder row so the two matched would be inventing an identity, which is the D-008 failure
  /// this whole surface exists to undo.
  ///
  /// `partners_self` gives a vendor exactly their own row; `partners_internal` gives an internal
  /// operator the org's book. Either way the ids come from Postgres, never from the UI.
  Future<({Set<String> ids, Map<String, Partner> partners})> _scope(
    String? viewerPartnerId,
  ) async {
    if (viewerPartnerId != null) {
      final row = await guardOrNull(
        () => _client.from('partners').select().eq('id', viewerPartnerId).maybeSingle(),
      );
      final partner = row == null ? null : Partner.fromJson(row);
      return (
        ids: <String>{viewerPartnerId},
        partners: partner == null
            ? const <String, Partner>{}
            : <String, Partner>{partner.id: partner},
      );
    }

    // The vendor desk. Inactive partners are included on purpose: a stage still sitting with a
    // foundry you have stopped using is exactly the row a production manager needs to see.
    final rows = await guard(() => _client.from('partners').select());
    final partners = <String, Partner>{};
    for (final row in rows) {
      final partner = Partner.fromJson(row);
      partners[partner.id] = partner;
    }
    return (ids: partners.keys.toSet(), partners: partners);
  }

  // -------------------------------------------------------------- one job

  /// Everything `/partner/<jobId>` renders.
  ///
  /// The reads are sequential on purpose. Running them with `.wait` would replace a [DhFailure] —
  /// which carries the server's own operator-facing sentence — with a `ParallelWaitError`, and
  /// those sentences are the product.
  Future<PartnerJobBrief> brief(String jobId, {String? viewerPartnerId}) async {
    final snapshot = await _jobs.getSnapshot(jobId);
    final stage = _stageFor(snapshot.rail, viewerPartnerId, jobId);

    final partnerId = stage.assignedPartner;
    final partner = partnerId == null ? null : await _readPartner(partnerId);

    final casting = stage.stage == LifecycleStage.casting
        ? await _production.castingParams(jobId)
        : null;
    final metal = await _specs.getMetalSpec(jobId);

    final files = await _store.forJob(jobId);
    final references = [
      for (final file in files)
        // The bucket is the sensitivity boundary, not the kind list — belt and braces, because
        // `attach_select` does not consider the bucket and a vault row would otherwise pass the
        // kind filter if one were ever mislabelled.
        if (referenceKinds.contains(file.kind) && !file.isInternalOnly) file,
    ];

    final photoId = casting?.photoId;
    final evidence =
        photoId == null ? null : files.firstWhereOrNull((file) => file.id == photoId);

    final toSign = <Attachment>[
      for (final file in references) if (file.isImage) file,
      if (evidence != null && evidence.isImage) evidence,
    ];
    final urls = toSign.isEmpty
        ? const <String, String>{}
        : await _store.signedUrls(toSign);

    final exceptions = [
      for (final e in await _jobs.listExceptions(jobId))
        if (e.stage == stage.stage) e,
    ];

    return PartnerJobBrief(
      job: snapshot.job,
      rail: snapshot.rail,
      stage: stage,
      viewerPartnerId: viewerPartnerId,
      partner: partner,
      casting: casting,
      metal: metal,
      references: List<Attachment>.unmodifiable(references),
      referenceUrls: urls,
      evidence: evidence,
      evidenceUrl: evidence == null ? null : urls[evidence.id],
      exceptions: List<JobException>.unmodifiable(exceptions),
    );
  }

  /// The rail row this brief is about.
  ///
  /// For a vendor it is the row assigned to *them* — a job can have both a casting stage and a
  /// certification stage out to two different partners, and a caster opening the job must not be
  /// shown the lab's row. For an internal operator it is whichever outsourced stage is live.
  JobStage _stageFor(StageRail rail, String? viewerPartnerId, String jobId) {
    final candidates = [
      for (final row in rail.stages)
        if (row.assignedPartner != null &&
            (viewerPartnerId == null || row.assignedPartner == viewerPartnerId))
          row,
    ];
    if (candidates.isEmpty) {
      throw RecordNotFound(
        message: viewerPartnerId == null
            ? 'No stage on this job is out with a partner. Open it from Jobs instead.'
            : 'This job is not with you any more. It may have been reassigned — pull down to '
                'refresh your queue.',
        detail: 'job_stages.assigned_partner is null for job=$jobId '
            'partner=${viewerPartnerId ?? 'any'}',
        code: 'partner_stage_missing',
      );
    }
    // The open one is the one being worked. Fall back to the furthest along, so a closed stage
    // still opens read-only instead of throwing.
    final open = candidates.where((row) => row.isActive || row.isBlocked).toList();
    if (open.isNotEmpty) return open.first;
    return candidates.reduce((a, b) => a.seq >= b.seq ? a : b);
  }

  Future<Partner?> _readPartner(String partnerId) async {
    final row = await guardOrNull(
      () => _client.from('partners').select().eq('id', partnerId).maybeSingle(),
    );
    return row == null ? null : Partner.fromJson(row);
  }
}

// ================================================================= providers

@Riverpod(keepAlive: true)
PartnerGateway partnerGateway(Ref ref) => PartnerGateway(
      ref.watch(supabaseProvider),
      ref.watch(attachmentStoreProvider),
      ref.watch(jobRepositoryProvider),
      ref.watch(productionRepositoryProvider),
      ref.watch(specRepositoryProvider),
    );

/// The session user's own partner id, or null for an internal operator.
///
/// D-008: this is `partner_users.partner_id`, which RLS restricts to `user_id = auth.uid()`.
/// There is no other source and no fallback — the mockup's "Assigned to Me" chip had nothing
/// behind it at all.
@Riverpod(keepAlive: true)
String? viewerPartnerId(Ref ref) =>
    ref.watch(currentUserProvider).value?.partnerId;

/// The queue, kept live.
///
/// New work arriving is the whole point of a queue, and a socket is what makes a stage that the
/// workshop just reassigned disappear from the wrong vendor's screen. `casting_params` is on the
/// channel because `evidence_ready` is derived from it — uploading a photo has to flip the row's
/// state without a pull to refresh.
@riverpod
Stream<Live<PartnerQueue>> partnerQueueLive(Ref ref) async* {
  // Every dependency is watched before the first await: watching after one is how a provider
  // ends up subscribed to a dependency it no longer has a live element for.
  final client = ref.watch(supabaseProvider);
  final gateway = ref.watch(partnerGatewayProvider);
  final viewer = await ref.watch(currentUserProvider.future);

  yield* liveQuery<PartnerQueue>(
    client: client,
    channelName: 'partner-queue:${viewer?.partnerId ?? 'desk'}',
    tables: const [
      LiveTable(table: 'job_stages'),
      LiveTable(table: 'casting_params'),
      LiveTable(table: 'job_exceptions'),
    ],
    read: () => gateway.queue(viewerPartnerId: viewer?.partnerId),
  );
}

/// One job's brief. Deliberately not live: a caster reads the temperatures off this card while
/// standing at the furnace, and a screen that reshuffles under their thumb is worse than one that
/// needs a pull to refresh. Every partner action invalidates it when it lands.
@riverpod
Future<PartnerJobBrief> partnerJobBrief(Ref ref, String jobId) async {
  final gateway = ref.watch(partnerGatewayProvider);
  final viewer = await ref.watch(currentUserProvider.future);
  return gateway.brief(jobId, viewerPartnerId: viewer?.partnerId);
}

// ================================================================= row parsing

/// Convention 7: Postgres sends instants in UTC and `DateTime.parse` keeps them that way. The
/// conversion to local time happens at render, never here.
DateTime? _instant(Object? value) {
  if (value is DateTime) return value;
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
  return null;
}
