/// The CAD loop's read layer: everything one decision needs, in one place.
///
/// Why this exists instead of more methods on `ProductionRepository`: that repository is
/// per-table and deliberately thin, while these screens are per-decision. A reviewer opening
/// `/cad/<revision>` needs the revision, the one before it, the pins on the render, every past
/// decision, the job, its rail and signed URLs for half a dozen images — and a screen that
/// renders four of those seven is showing a half-truth about an irreversible approval. Composing
/// them is a feature concern, so it lives here.
///
/// [DesignerQueue] has no source at all. "Elena Rostova — Lead CAD Designer" was named on four
/// mockups and owned none of them: nothing in the corpus answered "what am I drawing today".
/// This is that surface's data.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';

part 'cad_gateway.g.dart';

// ================================================================= file set

/// The `attachments` rows behind a revision's renders and mesh, with short-lived signed URLs for
/// the images among them.
///
/// Signed, never public — a public URL outlives the session, the job and the customer
/// relationship. A file that could not be signed is simply absent from [url], so a gallery draws
/// the rest of the renders instead of failing whole.
final class CadFileSet {
  const CadFileSet({required this.files, required this.urls});

  static const empty = CadFileSet(files: <String, Attachment>{}, urls: <String, String>{});

  /// Every row that came back, keyed by attachment id.
  final Map<String, Attachment> files;

  /// Signed URLs for the images among them, keyed by attachment id. A file that could not be
  /// signed is absent rather than present-and-broken.
  final Map<String, String> urls;

  Attachment? file(String? id) => id == null ? null : files[id];

  String? url(String? id) => id == null ? null : urls[id];

  /// The rows for [ids], in the order the designer arranged them, skipping any that have been
  /// deleted out from under the revision.
  List<Attachment> resolve(Iterable<String> ids) {
    final out = <Attachment>[];
    for (final id in ids) {
      final row = files[id];
      if (row != null) out.add(row);
    }
    return out;
  }

  bool get isEmpty => files.isEmpty;
}

// ================================================================= review bundle

/// One CAD decision, fully loaded.
final class CadReviewBundle {
  const CadReviewBundle({
    required this.job,
    required this.rail,
    required this.revision,
    required this.previous,
    required this.annotations,
    required this.reviews,
    required this.files,
    required this.people,
  });

  final Job job;

  /// D-005: where the job actually is. The decision here closes a stage, so the rail — not
  /// `jobs.current_stage` — decides which one.
  final StageRail rail;

  final CadRevision revision;

  /// The version this one is being compared against. Null on a first offer, which is why the
  /// split view has to degrade to a single pane rather than assume two.
  final CadRevision? previous;

  /// Oldest first — a review reads as a conversation down the image.
  final List<CadAnnotation> annotations;

  /// Newest first, as `cadReviews` returns them.
  final List<CadReview> reviews;

  final CadFileSet files;

  /// Designer, reviewers and pin authors, keyed by id. D-008: every name on screen came off a
  /// row, never a literal.
  final Map<String, AppUser> people;

  AppUser? person(String? id) => id == null ? null : people[id];

  String nameFor(String? id, {String fallback = 'Unrecorded'}) =>
      person(id)?.fullName ?? fallback;

  AppUser? get designer => person(revision.designerId);

  /// The decision of record on this revision, or null while it is still open.
  CadReview? get lastDecision => reviews.isEmpty ? null : reviews.first;

  /// The reviewer's note the designer has to act on — the whole point of
  /// `revision_response.dart`.
  CadReview? get openRevisionRequest {
    final last = lastDecision;
    return last != null && last.isRejection ? last : null;
  }

  List<CadAnnotation> get openAnnotations =>
      [for (final pin in annotations) if (pin.isOpen) pin];

  int get resolvedAnnotationCount => annotations.length - openAnnotations.length;

  List<Attachment> get currentRenders => files.resolve(revision.renderIds);

  List<Attachment> get previousRenders =>
      previous == null ? const <Attachment>[] : files.resolve(previous!.renderIds);

  Attachment? get model => files.file(revision.modelId);

  bool get canCompare => previousRenders.isNotEmpty && currentRenders.isNotEmpty;

  /// A locked revision is the record of what was agreed. Reviewing it again would rewrite
  /// history rather than move the job forward.
  bool get isSettled => !revision.isReviewable;

  /// The same derived vocabulary the queue uses, so the chip on the review header and the chip on
  /// the queue row can never disagree about one revision.
  CadWorkState get workState {
    if (revision.isLocked) return CadWorkState.approved;
    final last = lastDecision;
    if (last != null && last.isRejection) return CadWorkState.revisionsRequested;
    return CadWorkState.awaitingReview;
  }

  /// The stage an approval closes, or null when the job is not standing anywhere an approval can
  /// close.
  ///
  /// D-002 puts `cad` and `approval` next to each other on the rail: the designer's work is
  /// reviewed at `cad`, and the same screen is where a design sitting at `approval` is signed
  /// off. Anything else — a job already at `wax`, a rail not yet seeded — must not be advanced by
  /// a CAD approval, and saying so beats guessing.
  JobStage? get stageToClose {
    final active = rail.activeStage;
    if (active == null) return null;
    return switch (active.stage) {
      LifecycleStage.cad || LifecycleStage.approval => active,
      _ => null,
    };
  }

  /// Why an approval will not move the job, for the confirm dialog to say out loud.
  String? get advanceNote {
    if (stageToClose != null) return null;
    final active = rail.activeStage;
    if (active == null) {
      return 'This job has no active stage, so approving records the decision without moving '
          'anything.';
    }
    return 'The job is at ${active.stage.label}, which a CAD approval does not close. The '
        'decision is recorded and the rail stays where it is.';
  }
}

// ================================================================= queue

/// What is actually outstanding on one job's CAD, derived rather than stored.
///
/// There is no `cad_status` column and there must not be one: the state is a fact about the rows
/// that exist (D-005 in miniature). A revision with no decision is waiting on a reviewer; a
/// revision whose newest decision is a rejection is waiting on the designer.
enum CadWorkState {
  unassigned(
    'Unassigned',
    'Nobody is drawing this yet.',
  ),
  drawing(
    'Drawing',
    'Assigned. No version has been offered yet.',
  ),
  awaitingReview(
    'Awaiting review',
    'Offered and waiting on a decision.',
  ),
  revisionsRequested(
    'Revisions requested',
    'The reviewer sent it back with a note.',
  ),
  approved(
    'Approved',
    'The version is locked and the design is released.',
  );

  const CadWorkState(this.label, this.blurb);

  final String label;
  final String blurb;

  /// The two states that are the designer's move.
  bool get isDesignerWork => this == drawing || this == revisionsRequested;

  /// Waiting on somebody with the design-approval capability.
  bool get isReviewerWork => this == awaitingReview;
}

/// One row of the designer's queue.
final class CadQueueItem {
  const CadQueueItem({required this.job, required this.revision, required this.decision});

  final JobListItem job;

  /// The revision on the table right now, or null before the first offer.
  final CadRevision? revision;

  /// The newest decision on [revision].
  final CadReview? decision;

  CadWorkState get state {
    final offered = revision;
    if (offered == null) {
      return job.assignedTo == null ? CadWorkState.unassigned : CadWorkState.drawing;
    }
    if (offered.isLocked) return CadWorkState.approved;
    if (decision?.isRejection ?? false) return CadWorkState.revisionsRequested;
    return CadWorkState.awaitingReview;
  }

  bool get isUnassigned => job.assignedTo == null;

  bool isHeldBy(String? userId) => userId != null && job.assignedTo == userId;

  /// 'v1.2' — or an em dash before the first offer, never a blank cell.
  String get versionLabel => revision?.version ?? '—';

  /// The note the designer has to answer, when there is one.
  String? get requestComment =>
      (decision?.isRejection ?? false) ? decision?.comment : null;
}

/// Every job with CAD work outstanding, split the way a designer thinks about it.
final class DesignerQueue {
  const DesignerQueue({required this.items, required this.viewerId});

  static const empty = DesignerQueue(items: <CadQueueItem>[], viewerId: null);

  final List<CadQueueItem> items;

  /// D-008: "mine" is the signed-in operator's id, not a decorative chip. `caster_dashboard`
  /// scoped its queue with an "Assigned to Me" pill that had nothing behind it.
  final String? viewerId;

  List<CadQueueItem> get mine =>
      [for (final item in items) if (item.isHeldBy(viewerId)) item];

  List<CadQueueItem> get unassigned =>
      [for (final item in items) if (item.isUnassigned) item];

  /// Held by somebody else — visible so a manager can see the whole board, and so a designer
  /// knows who to ask.
  List<CadQueueItem> get elsewhere => [
        for (final item in items)
          if (!item.isUnassigned && !item.isHeldBy(viewerId)) item,
      ];

  List<CadQueueItem> forScope(CadQueueScope scope) => switch (scope) {
        CadQueueScope.mine => mine,
        CadQueueScope.unassigned => unassigned,
        CadQueueScope.everyone => items,
      };

  int get sentBackCount =>
      items.where((i) => i.state == CadWorkState.revisionsRequested).length;

  int get awaitingReviewCount =>
      items.where((i) => i.state == CadWorkState.awaitingReview).length;

  bool get isEmpty => items.isEmpty;

  /// How much unfinished CAD each designer is already carrying, for the assignment picker.
  /// An approved revision is finished work and does not count against anybody.
  Map<String, int> get workloadByUser {
    final out = <String, int>{};
    for (final item in items) {
      final holder = item.job.assignedTo;
      if (holder == null || item.state == CadWorkState.approved) continue;
      out[holder] = (out[holder] ?? 0) + 1;
    }
    return out;
  }
}

/// Which slice of the queue is on screen.
enum CadQueueScope {
  mine('Mine'),
  unassigned('Unclaimed'),
  everyone('All CAD');

  const CadQueueScope(this.label);

  final String label;
}

// ================================================================= upload context

/// What the upload screen opens with: the job, the version it follows, and the number to suggest.
final class RevisionContext {
  const RevisionContext({required this.job, required this.rail, required this.latest});

  final Job job;
  final StageRail rail;

  /// The current revision this one supersedes, or null for a first offer.
  final CadRevision? latest;

  bool get isFirstOffer => latest == null;

  /// The number to prefill.
  ///
  /// A version that follows an approved, locked one is a new design direction, so it takes the
  /// major: `v1.2` approved then reopened becomes `v2.0`. A version answering a revision request
  /// is the same design again, so it takes the minor: `v1.2` becomes `v1.3`. The field stays
  /// editable — the shop's own numbering is not ours to enforce, and `cad_revisions` only
  /// requires it to be unique per job.
  String get suggestedVersion =>
      nextVersion(latest?.version, afterApproval: latest?.isLocked ?? false);

  static String nextVersion(String? previous, {required bool afterApproval}) {
    final text = previous?.trim() ?? '';
    if (text.isEmpty) return 'v1.0';
    final match = RegExp(r'^[vV]?(\d+)(?:\.(\d+))?$').firstMatch(text);
    if (match == null) {
      // Unparseable shop numbering — offer something obviously new rather than mangling it.
      return afterApproval ? '$text.next' : '$text.1';
    }
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2) ?? '0');
    return afterApproval ? 'v${major + 1}.0' : 'v$major.${minor + 1}';
  }
}

// ================================================================= gateway

final class CadGateway {
  const CadGateway(this._client, this._store, this._jobs, this._production);

  final SupabaseClient _client;
  final AttachmentStore _store;
  final JobRepository _jobs;
  final ProductionRepository _production;

  /// The `app_users` columns a name and an avatar need. `user_roles` is not joined: this is for
  /// rendering who did what, and a role badge is not part of that.
  static const _peopleSelect = 'id, org_id, principal, full_name, title, initials, email, '
      'phone, avatar_path, is_active, created_at';

  // -------------------------------------------------------------- one decision

  /// Everything `/cad/<revisionId>` renders.
  ///
  /// The reads are sequential on purpose. Running them in parallel with `.wait` would replace a
  /// [DhFailure] — which carries the server's own operator-facing sentence — with a
  /// `ParallelWaitError`, and those sentences are the product.
  Future<CadReviewBundle> reviewBundle(String revisionId) async {
    final revision = await readRevision(revisionId);
    final previous = await previousTo(revision);
    final snapshot = await _jobs.getSnapshot(revision.jobId);
    final annotations = await _production.cadAnnotations(revisionId);
    final reviews = await _production.cadReviews(revisionId);

    final files = await filesFor(<String?>[
      ...revision.renderIds,
      revision.modelId,
      ...?previous?.renderIds,
      previous?.modelId,
    ]);

    final people = await peopleFor(<String?>[
      revision.designerId,
      previous?.designerId,
      for (final review in reviews) review.reviewerId,
      for (final pin in annotations) pin.authorId,
    ]);

    return CadReviewBundle(
      job: snapshot.job,
      rail: snapshot.rail,
      revision: revision,
      previous: previous,
      annotations: annotations,
      reviews: reviews,
      files: files,
      people: people,
    );
  }

  Future<CadRevision> readRevision(String revisionId) async {
    final row = await guard(
      () => _client.from('cad_revisions').select().eq('id', revisionId).maybeSingle(),
    );
    if (row == null) {
      throw RecordNotFound(
        message: 'That CAD revision is not on file. It may have been superseded — open the job '
            'and take the current version.',
        detail: 'cad_revisions.id = $revisionId',
        code: 'cad_revision_missing',
      );
    }
    return CadRevision.fromJson(row);
  }

  /// The version immediately before [revision] on the same job — the left-hand pane of the
  /// split view.
  Future<CadRevision?> previousTo(CadRevision revision) async {
    final row = await guardOrNull(
      () => _client
          .from('cad_revisions')
          .select()
          .eq('job_id', revision.jobId)
          .lt('seq', revision.seq)
          .order('seq', ascending: false)
          .limit(1)
          .maybeSingle(),
    );
    return row == null ? null : CadRevision.fromJson(row);
  }

  /// Attachment rows plus signed URLs for the images among them.
  Future<CadFileSet> filesFor(Iterable<String?> ids) async {
    final wanted = <String>{for (final id in ids) if (id != null) id};
    if (wanted.isEmpty) return CadFileSet.empty;

    final rows = await guard(
      () => _client.from('attachments').select().inFilter('id', wanted.toList()),
    );
    final files = [for (final row in rows) Attachment.fromJson(row)];
    final images = [for (final file in files) if (file.isImage) file];
    final urls = images.isEmpty
        ? const <String, String>{}
        : await _store.signedUrls(images);

    return CadFileSet(
      files: {for (final file in files) file.id: file},
      urls: urls,
    );
  }

  /// The people behind a set of ids, for the names on screen.
  Future<Map<String, AppUser>> peopleFor(Iterable<String?> ids) async {
    final wanted = <String>{for (final id in ids) if (id != null) id};
    if (wanted.isEmpty) return const <String, AppUser>{};

    final rows = await guard(
      () => _client.from('app_users').select(_peopleSelect).inFilter('id', wanted.toList()),
    );
    final out = <String, AppUser>{};
    for (final row in rows) {
      final user = AppUser.fromJson(row);
      out[user.id] = user;
    }
    return out;
  }

  // -------------------------------------------------------------- the queue

  /// Every job with CAD work outstanding.
  ///
  /// Two stages are read, not one. A job at `cad` is always the designer's business. A job at
  /// `approval` normally is not — it is with whoever signs designs off — *except* when the
  /// newest decision on its current revision is a rejection, because then the work is back in
  /// the designer's hands even though the rail has not moved. D-005 is append-only: a rejection
  /// does not walk the job backwards, so the queue has to notice it instead.
  Future<DesignerQueue> queue({String? viewerId}) async {
    final jobs = await _jobs.fetchJobList(
      const JobListFilter(
        stages: {LifecycleStage.cad, LifecycleStage.approval},
        draftScope: DraftScope.committedOnly,
        sort: JobListSort.longestInStage,
      ),
    );
    if (jobs.isEmpty) return DesignerQueue(items: const <CadQueueItem>[], viewerId: viewerId);

    final revisions = await currentRevisionsFor([for (final job in jobs) job.id]);
    final decisions = await latestDecisionsFor(
      [for (final revision in revisions.values) revision.id],
    );

    final items = <CadQueueItem>[];
    for (final job in jobs) {
      final revision = revisions[job.id];
      final item = CadQueueItem(
        job: job,
        revision: revision,
        decision: revision == null ? null : decisions[revision.id],
      );
      final atApproval = job.currentStage == LifecycleStage.approval;
      if (atApproval && item.state != CadWorkState.revisionsRequested) continue;
      items.add(item);
    }
    return DesignerQueue(items: items, viewerId: viewerId);
  }

  /// The current revision of each job, keyed by job id.
  Future<Map<String, CadRevision>> currentRevisionsFor(List<String> jobIds) async {
    if (jobIds.isEmpty) return const <String, CadRevision>{};
    final rows = await guard(
      () => _client
          .from('cad_revisions')
          .select()
          .inFilter('job_id', jobIds)
          .eq('is_current', true)
          .order('seq', ascending: false),
    );
    final out = <String, CadRevision>{};
    for (final row in rows) {
      final revision = CadRevision.fromJson(row);
      // Newest seq first, so the first row seen for a job is the one that counts. A second row
      // would mean two revisions both claim to be current, which is a bug, not a state.
      out.putIfAbsent(revision.jobId, () => revision);
    }
    return out;
  }

  /// The newest decision on each revision, keyed by revision id.
  Future<Map<String, CadReview>> latestDecisionsFor(List<String> revisionIds) async {
    if (revisionIds.isEmpty) return const <String, CadReview>{};
    final rows = await guard(
      () => _client
          .from('cad_reviews')
          .select()
          .inFilter('revision_id', revisionIds)
          .order('created_at', ascending: false),
    );
    final out = <String, CadReview>{};
    for (final row in rows) {
      final review = CadReview.fromJson(row);
      out.putIfAbsent(review.revisionId, () => review);
    }
    return out;
  }

  // -------------------------------------------------------------- upload context

  Future<RevisionContext> revisionContext(String jobId) async {
    final snapshot = await _jobs.getSnapshot(jobId);
    final latest = await _production.currentCadRevision(jobId);
    return RevisionContext(job: snapshot.job, rail: snapshot.rail, latest: latest);
  }
}

// ================================================================= providers

@Riverpod(keepAlive: true)
CadGateway cadGateway(Ref ref) => CadGateway(
      ref.watch(supabaseProvider),
      ref.watch(attachmentStoreProvider),
      ref.watch(jobRepositoryProvider),
      ref.watch(productionRepositoryProvider),
    );

/// One decision, re-read on demand. Deliberately not live: an approval is irreversible, and a
/// screen that reshuffles its panes under the operator's thumb mid-decision is worse than one
/// that needs a pull to refresh. Every CAD action invalidates this when it lands.
@riverpod
Future<CadReviewBundle> cadReviewBundle(Ref ref, String revisionId) =>
    ref.watch(cadGatewayProvider).reviewBundle(revisionId);

/// The queue, kept live. New work arriving is the whole point of a queue, and a socket is what
/// makes a claimed job disappear from every other designer's screen.
@riverpod
Stream<Live<DesignerQueue>> designerQueueLive(Ref ref) async* {
  // Every dependency is watched before the first await. Watching after one is how a provider
  // ends up subscribed to a dependency it no longer has a live element for.
  final client = ref.watch(supabaseProvider);
  final gateway = ref.watch(cadGatewayProvider);
  final viewer = await ref.watch(currentUserProvider.future);

  yield* liveQuery<DesignerQueue>(
    client: client,
    channelName: 'cad-designer-queue',
    tables: const [
      LiveTable(table: 'job_stages'),
      LiveTable(table: 'cad_revisions'),
      LiveTable(table: 'cad_reviews'),
    ],
    read: () => gateway.queue(viewerId: viewer?.id),
  );
}

/// Unfinished CAD per designer, for the assignment picker. Derived from the queue that is
/// already open, so opening the picker costs no extra round trip.
@riverpod
Map<String, int> cadWorkload(Ref ref) =>
    ref.watch(designerQueueLiveProvider).valueOrNull?.data.workloadByUser ??
    const <String, int>{};

@riverpod
Future<RevisionContext> revisionContext(Ref ref, String jobId) =>
    ref.watch(cadGatewayProvider).revisionContext(jobId);
