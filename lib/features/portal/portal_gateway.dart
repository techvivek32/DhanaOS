/// The retailer's read layer.
///
/// The mockups named "Client Portal" as an actor in `certification`'s audit trail and offered
/// "Customer" as a sign-off authority on `quality_acceptance` — and then shipped four exports, 46
/// screens, without a single customer-facing surface. Everything a retailer was promised existed
/// only as a name in somebody else's feed. This is that surface's data.
///
/// **Scope.** Postgres is the authority: `auth_can_see_job` restricts a customer principal to
/// `jobs.customer_id = auth_customer()`, and that holds whatever this file does. Every read below
/// also filters on the customer id from the session's own `customer_users` row, which is defence
/// in depth for one reason — `v_job_list` is a *view*, and a view is not a policy. Rather than
/// lean on it, the portal reads the base tables, where RLS genuinely applies.
///
/// **Two leaks this file closes in the client because the schema does not.**
///
///  * `attach_select` lets a customer read every `attachments` row on their job, including the
///    `vault` ones — QC evidence and stone valuation photography. [Attachment.isInternalOnly]
///    exists for exactly this, and [PortalGateway.customerDocumentKinds] narrows it further: the
///    STL and the CAD source are the workshop's design asset, and handing a retailer the mesh is
///    giving the design away.
///  * `quotes_select` (the generic job-scoped policy) overlaps `quotes_customer_read` and so lets
///    a customer read a *draft* quote — a price nobody has agreed to show them. Every quote read
///    here excludes drafts.
///
/// Both belong in a migration. Until they are there, the filters are the difference between a
/// portal and a leak, so they are stated out loud rather than assumed.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';

part 'portal_gateway.g.dart';

// ================================================================= what a customer is told

/// The pipeline as a retailer reads it.
///
/// D-002's 14 stages are the workshop's vocabulary and stay the workshop's — a client does not
/// need to know the difference between `assembly` and `setting` to know where their ring is. This
/// is a *presentation* grouping over the same enum, not a second one: the rail is still the truth
/// and [PortalJobView.railNodes] still renders all fourteen.
enum PortalPhase {
  designing('Designing', 'We are drawing your piece and agreeing the details.'),
  pricing('Pricing', 'We are putting the quote together for you to approve.'),
  making('Being made', 'Your piece is on the bench.'),
  checking('Final checks', 'Quality control and certification.'),
  onItsWay('On its way', 'Packed and moving.'),
  delivered('Delivered', 'Handed over.');

  const PortalPhase(this.label, this.blurb);

  final String label;
  final String blurb;

  static PortalPhase of(LifecycleStage? stage) => switch (stage) {
        null || LifecycleStage.inquiry || LifecycleStage.cad || LifecycleStage.approval =>
          designing,
        LifecycleStage.pricing || LifecycleStage.finalApp => pricing,
        LifecycleStage.wax ||
        LifecycleStage.casting ||
        LifecycleStage.assembly ||
        LifecycleStage.setting ||
        LifecycleStage.polishing =>
          making,
        LifecycleStage.qc || LifecycleStage.cert => checking,
        LifecycleStage.dispatch => onItsWay,
        LifecycleStage.delivered => delivered,
      };
}

// ================================================================= one card

/// One of the customer's own jobs, for the list.
///
/// `jobs.current_stage` is the D-005 cache and this is exactly what it exists for — "so a 200-row
/// list does not need 200 sub-queries". The detail screen reads the rail itself, which is the
/// truth when the two ever disagree.
final class PortalJobCard {
  const PortalJobCard(this.job);

  final Job job;

  String get id => job.id;

  /// D-001: 'DH-2026-01842' after commit, 'DRAFT-992A' before. A retailer normally never sees a
  /// draft — the portal lists committed work — but the code renders either way.
  String get code => job.displayCode;

  String get title => job.displayTitle;

  PortalPhase get phase => PortalPhase.of(job.currentStage);

  /// 0.0 .. 1.0 across the 14-stage rail, from the cache. Approximate by construction: the
  /// detail screen computes the real figure from the rail rows.
  double get progress {
    final stage = job.currentStage;
    if (job.status == JobStatus.completed) return 1;
    if (stage == null) return 0;
    return (stage.seq / LifecycleStage.values.length).clamp(0.0, 1.0);
  }

  /// What the client agreed to, falling back to what they asked for.
  DateTime? get dueDate => job.promisedDelivery ?? job.requestedDelivery;

  bool get isOpen => job.isOpen;

  /// A job standing still because the workshop is waiting on something. `JobStatus.onHold` is
  /// D-006's addition — every gate in the mockups was one-way and had no such state.
  bool get isPaused => job.status == JobStatus.onHold;

  bool get isFinished =>
      job.status == JobStatus.completed || job.currentStage == LifecycleStage.delivered;
}

// ================================================================= one job

/// Everything `/portal/<jobId>` renders.
final class PortalJobView {
  const PortalJobView({
    required this.job,
    required this.rail,
    required this.documents,
    required this.documentUrls,
    required this.shipments,
    this.quote,
    this.certificate,
  });

  final Job job;

  /// D-005: the rail is the truth about where the job is.
  final StageRail rail;

  /// Customer-visible files only. See [PortalGateway.customerDocumentKinds].
  final List<Attachment> documents;

  /// Short-lived signed URLs for the images among them, keyed by attachment id.
  final Map<String, String> documentUrls;

  /// Legs of the journey. A customer sees the final dispatch; the internal hops are the
  /// workshop's business and are filtered out.
  final List<Shipment> shipments;

  /// The newest non-draft quote, or null before there is a price to show.
  final Quote? quote;

  final Certificate? certificate;

  PortalPhase get phase => PortalPhase.of(rail.activeLifecycle ?? job.currentStage);

  /// The real figure, over all 14 stages (D-002) rather than over the rows that happen to exist,
  /// so a partially seeded rail cannot read as finished.
  double get progress => rail.isEmpty
      ? (job.status == JobStatus.completed ? 1 : 0)
      : rail.progress;

  LifecycleStage? get currentStage => rail.activeLifecycle ?? job.currentStage;

  JobStage? get nextStage => rail.nextStage;

  /// What happens next, in a sentence. A progress bar with no words beside it tells a client
  /// nothing they can act on.
  String get nextStepLabel {
    if (job.status == JobStatus.completed) return 'Finished and handed over.';
    if (job.status == JobStatus.cancelled) return 'This order was cancelled.';
    if (job.status == JobStatus.onHold) {
      return 'Paused. The workshop will be in touch about what they need.';
    }
    final next = nextStage;
    if (next == null) return PortalPhase.of(currentStage).blurb;
    return '${PortalPhase.of(currentStage).blurb} Next: ${PortalPhase.of(next.stage).label}.';
  }

  /// The price of record, if there is an agreed one.
  Money? get agreedTotal =>
      quote != null && quote!.status == QuoteStatus.approved ? quote!.grandTotal : null;

  DateTime? get dueDate => job.promisedDelivery ?? job.requestedDelivery;

  /// The leg that is actually going to the client.
  Shipment? get outboundShipment {
    for (final leg in shipments) {
      if (leg.leg == ShipmentLeg.finalDispatch) return leg;
    }
    return null;
  }

  bool get hasCertificate => certificate?.isComplete ?? false;

  // The 14 rail nodes are NOT built here. `StageNode` is a widget-layer value type from
  // `shared/widgets/stage_rail.dart`, and a read model that returned one would make this layer
  // depend on the component set. `portal_job.dart` maps `rail` to nodes in one expression.
}

// ================================================================= decisions

/// The three things a retailer is actually asked to decide.
enum PortalDecisionKind {
  design(
    'Design',
    'The CAD drawing of your piece.',
    'Approve the design',
    'Ask for changes',
  ),
  wax(
    'Wax model',
    'The wax we will cast your piece from.',
    'Approve the wax',
    'Ask for changes',
  ),
  price(
    'Price',
    'The quote for the work.',
    'Approve the price',
    'Refuse the price',
  );

  const PortalDecisionKind(this.label, this.blurb, this.approveLabel, this.refuseLabel);

  final String label;
  final String blurb;

  /// Buttons say what happens (convention 8).
  final String approveLabel;
  final String refuseLabel;
}

/// One decision the customer is being asked for, or one already made.
final class PortalApprovalItem {
  const PortalApprovalItem({
    required this.kind,
    required this.job,
    this.revision,
    this.lastReview,
    this.quote,
    this.waxStage,
    this.waxDecision,
    this.renders = const <Attachment>[],
    this.renderUrls = const <String, String>{},
  });

  final PortalDecisionKind kind;
  final Job job;

  /// Design decisions only — the version on the table.
  final CadRevision? revision;

  /// The newest decision already recorded against [revision].
  final CadReview? lastReview;

  /// Price decisions only.
  final Quote? quote;

  /// Wax decisions only — the rail row the job is standing on.
  final JobStage? waxStage;

  /// The audit row that already settled the wax, if there is one. D-005: a customer's sign-off is
  /// an immutable `activity_events` entry, which is what makes "who approved what, when"
  /// reconstructible — the thing `certification` called an Immutable Audit Trail and never built.
  final ActivityEvent? waxDecision;

  final List<Attachment> renders;
  final Map<String, String> renderUrls;

  String get jobId => job.id;

  /// Waiting on the customer right now.
  bool get isOutstanding => switch (kind) {
        PortalDecisionKind.design =>
          revision != null && !revision!.isLocked && lastReview == null,
        PortalDecisionKind.wax => waxStage != null && waxDecision == null,
        PortalDecisionKind.price => quote != null && quote!.status == QuoteStatus.sent,
      };

  /// Settled, whichever way it went.
  bool get isDecided => switch (kind) {
        PortalDecisionKind.design => lastReview != null || (revision?.isLocked ?? false),
        PortalDecisionKind.wax => waxDecision != null,
        PortalDecisionKind.price => quote != null && quote!.isDecided,
      };

  /// True when the customer said no and the ball is back with the workshop.
  bool get isSentBack => switch (kind) {
        PortalDecisionKind.design => lastReview?.isRejection ?? false,
        PortalDecisionKind.wax => waxDecision?.kind == ActivityKind.rejected,
        PortalDecisionKind.price =>
          quote?.status == QuoteStatus.rejected ||
              quote?.status == QuoteStatus.counterOffered,
      };

  /// 'CAD v2.0' / 'Quote v3' / 'Wax model' — the thing being decided, monospaced where it is an
  /// identifier.
  String get subjectLabel => switch (kind) {
        PortalDecisionKind.design => revision == null ? '—' : 'CAD ${revision!.version}',
        PortalDecisionKind.price => quote == null ? '—' : 'Quote v${quote!.version}',
        PortalDecisionKind.wax => 'Wax model',
      };

  /// What the customer sees on the card before they open anything.
  String get statusLabel {
    if (isOutstanding) return 'Waiting for you';
    if (isSentBack) return 'Back with the workshop';
    if (isDecided) return 'Approved';
    return 'Not ready yet';
  }

  /// The money on the table, or null for a design or wax decision.
  Money? get amount => quote?.grandTotal;

  /// When the customer was asked. Null when the workshop has not sent it yet.
  DateTime? get askedAt => switch (kind) {
        PortalDecisionKind.design => revision?.createdAt,
        PortalDecisionKind.price => quote?.sentAt ?? quote?.createdAt,
        PortalDecisionKind.wax => waxStage?.enteredAt,
      };

  /// The note attached to the last decision, so a customer re-opening the screen sees what they
  /// said rather than an unexplained "Back with the workshop".
  String? get lastNote => switch (kind) {
        PortalDecisionKind.design => lastReview?.comment,
        PortalDecisionKind.price => quote?.decisionNote,
        PortalDecisionKind.wax => waxDecision?.detail,
      };
}

/// Every decision across every one of the customer's jobs.
final class PortalApprovals {
  const PortalApprovals(this.items);

  static const empty = PortalApprovals(<PortalApprovalItem>[]);

  /// Outstanding first, then the settled ones newest-asked first.
  final List<PortalApprovalItem> items;

  List<PortalApprovalItem> get outstanding =>
      [for (final item in items) if (item.isOutstanding) item];

  List<PortalApprovalItem> get settled =>
      [for (final item in items) if (!item.isOutstanding) item];

  int get outstandingCount => outstanding.length;

  bool get isEmpty => items.isEmpty;

  /// The money the customer is being asked to agree to right now.
  Money? get awaitingPrice {
    for (final item in outstanding) {
      if (item.kind == PortalDecisionKind.price) return item.amount;
    }
    return null;
  }
}

// ================================================================= gateway

final class PortalGateway {
  const PortalGateway(this._client, this._store, this._identity);

  final SupabaseClient _client;
  final AttachmentStore _store;

  /// D-008: the actor on a customer's own sign-off comes from the signed-in operator's
  /// `app_users` row and from nowhere else.
  final RepoIdentity _identity;

  /// What the portal reads off `jobs`. Named rather than `*` on purpose: `is_at_risk`,
  /// `hold_reason`, `cancel_reason` and `wizard_step` are the workshop's internal working notes,
  /// and a column list is a boundary a future migration cannot quietly widen.
  static const _jobColumns = 'id, org_id, customer_id, code, draft_code, title, job_type, '
      'category, sub_style, quantity, status, priority, current_stage, stage_entered_at, '
      'requested_delivery, promised_delivery, currency, created_at, updated_at, committed_at, '
      'closed_at';

  /// Which files a retailer may see.
  ///
  /// Not simply "everything not in the vault". `stl` and `cad_file` are the workshop's design
  /// asset — handing a client the mesh is handing over the design — so a render is shared and the
  /// model is not. QC evidence and stone photography are vault-bucketed and excluded twice over.
  static const customerDocumentKinds = <AttachmentKind>[
    AttachmentKind.referenceImage,
    AttachmentKind.sketch,
    AttachmentKind.cadRender,
    AttachmentKind.voiceNote,
    AttachmentKind.certificatePdf,
    AttachmentKind.invoice,
    AttachmentKind.proofOfDelivery,
  ];

  /// Quote statuses a customer may ever be shown. `draft` is a price nobody has agreed to show
  /// them yet; the generic `quotes_select` policy would otherwise let it through.
  static List<String> get _visibleQuoteStatuses => [
        for (final status in QuoteStatus.values)
          if (status != QuoteStatus.draft) status.wire,
      ];

  // -------------------------------------------------------------- the list

  /// The customer's own jobs, newest code first.
  ///
  /// Reads `jobs` rather than `v_job_list` so RLS is genuinely the thing doing the scoping —
  /// `jobs_select using (auth_can_see_job(id))` is a policy on a table, not a view that may or may
  /// not run with `security_invoker`.
  Future<List<PortalJobCard>> jobs({required String customerId, bool openOnly = false}) async {
    final rows = await guard(() {
      var query = _client.from('jobs').select(_jobColumns).eq('customer_id', customerId);
      if (openOnly) {
        query = query.inFilter(
          'status',
          [for (final status in JobStatus.values) if (status.isOpen) status.wire],
        );
      }
      // D-001 codes are year-scoped and zero-padded, so they sort correctly as text and newest
      // first is simply descending.
      return query.order('code', ascending: false, nullsFirst: false).order('created_at',
          ascending: false);
    });
    return [for (final row in rows) PortalJobCard(Job.fromJson(row))];
  }

  // -------------------------------------------------------------- one job

  /// Everything `/portal/<jobId>` renders.
  ///
  /// The reads are sequential on purpose: running them with `.wait` would replace a [DhFailure] —
  /// which carries the server's own operator-facing sentence — with a `ParallelWaitError`.
  Future<PortalJobView> jobView(String jobId) async {
    final row = await guardOrNull(
      () => _client.from('jobs').select(_jobColumns).eq('id', jobId).maybeSingle(),
    );
    if (row == null) {
      throw RecordNotFound(
        message: 'That order is not on your account. Check the link, or open it from your orders '
            'list.',
        detail: 'jobs.id=$jobId',
        code: 'portal_job_missing',
      );
    }
    final job = Job.fromJson(row);

    final stageRows = await guard(
      () => _client.from('job_stages').select().eq('job_id', jobId).order('seq'),
    );
    final rail = StageRail.of([for (final stage in stageRows) JobStage.fromJson(stage)]);

    final documents = await _documentsFor(jobId);
    final images = [for (final file in documents) if (file.isImage) file];
    final urls =
        images.isEmpty ? const <String, String>{} : await _store.signedUrls(images);

    final quote = await latestQuote(jobId);
    final certificate = await _certificateFor(jobId);
    final shipments = await _shipmentsFor(jobId);

    return PortalJobView(
      job: job,
      rail: rail,
      documents: documents,
      documentUrls: urls,
      shipments: shipments,
      quote: quote,
      certificate: certificate,
    );
  }

  /// Customer-visible files, newest first. Filtered twice: by bucket, because `attach_select` does
  /// not consider it, and by kind, because a render is shareable and the mesh behind it is not.
  Future<List<Attachment>> _documentsFor(String jobId) async {
    final rows = await guard(
      () => _client
          .from('attachments')
          .select()
          .eq('job_id', jobId)
          .inFilter('kind', [for (final kind in customerDocumentKinds) kind.wire])
          .order('created_at', ascending: false),
    );
    final files = [for (final row in rows) Attachment.fromJson(row)];
    // The second filter. `attach_select` does not look at the bucket, so a vault row mislabelled
    // with a customer-visible kind would otherwise reach the portal.
    return [for (final file in files) if (!file.isInternalOnly) file];
  }

  Future<Certificate?> _certificateFor(String jobId) async {
    final row = await guardOrNull(
      () => _client
          .from('certificates')
          .select()
          .eq('job_id', jobId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle(),
    );
    return row == null ? null : Certificate.fromJson(row);
  }

  /// The legs a client is entitled to. The wax hop to a hub and the trip to the gem lab are the
  /// workshop's logistics, not the customer's order status.
  Future<List<Shipment>> _shipmentsFor(String jobId) async {
    final rows = await guard(
      () => _client
          .from('shipments')
          .select()
          .eq('job_id', jobId)
          .eq('leg', ShipmentLeg.finalDispatch.wire)
          .order('created_at', ascending: false),
    );
    return [for (final row in rows) Shipment.fromJson(row)];
  }

  /// The newest quote a customer may see. Never a draft.
  Future<Quote?> latestQuote(String jobId) async {
    final row = await guardOrNull(
      () => _client
          .from('quotes')
          .select('*, cost_lines(*)')
          .eq('job_id', jobId)
          .inFilter('status', _visibleQuoteStatuses)
          .order('version', ascending: false)
          .limit(1)
          .maybeSingle(),
    );
    return row == null ? null : Quote.fromJson(row);
  }

  // -------------------------------------------------------------- decisions

  /// Every decision across the customer's open jobs, batched rather than fetched per job.
  Future<PortalApprovals> approvals({required String customerId}) async {
    final cards = await jobs(customerId: customerId, openOnly: true);
    if (cards.isEmpty) return PortalApprovals.empty;

    final byId = <String, Job>{for (final card in cards) card.id: card.job};
    final ids = byId.keys.toList();

    final revisions = await _currentRevisions(ids);
    final reviews = await _latestReviews([for (final r in revisions.values) r.id]);
    final quotes = await _quotesFor(ids);
    final waxStages = await _waxStages(ids);
    final acceptance = await _acceptanceFor(ids);
    final waxDecisions = await _waxDecisions(ids);

    final renderIds = <String>{
      for (final revision in revisions.values) ...revision.renderIds,
    };
    final renders = await _rendersFor(renderIds);
    final renderUrls = renders.isEmpty
        ? const <String, String>{}
        : await _store.signedUrls([for (final file in renders) if (file.isImage) file]);
    final rendersById = {for (final file in renders) file.id: file};

    final items = <PortalApprovalItem>[];
    for (final id in ids) {
      final job = byId[id]!;

      final revision = revisions[id];
      if (revision != null) {
        items.add(
          PortalApprovalItem(
            kind: PortalDecisionKind.design,
            job: job,
            revision: revision,
            lastReview: reviews[revision.id],
            renders: [
              for (final renderId in revision.renderIds)
                if (rendersById[renderId] case final file?) file,
            ],
            renderUrls: renderUrls,
          ),
        );
      }

      // The wax gate exists only where the shop agreed the client signs it off
      // (`acceptance_criteria.authority = 'customer'`). Without that condition the portal would
      // nag every retailer about every wax, which is how a gate stops being read.
      final waxStage = waxStages[id];
      final authority = acceptance[id];
      if (waxStage != null && (authority?.needsCustomerGate ?? false)) {
        items.add(
          PortalApprovalItem(
            kind: PortalDecisionKind.wax,
            job: job,
            waxStage: waxStage,
            waxDecision: waxDecisions[id],
          ),
        );
      }

      final quote = quotes[id];
      if (quote != null) {
        items.add(PortalApprovalItem(kind: PortalDecisionKind.price, job: job, quote: quote));
      }
    }

    items.sort((a, b) {
      if (a.isOutstanding != b.isOutstanding) return a.isOutstanding ? -1 : 1;
      final left = a.askedAt;
      final right = b.askedAt;
      if (left == null || right == null) return 0;
      return right.compareTo(left);
    });

    return PortalApprovals(List<PortalApprovalItem>.unmodifiable(items));
  }

  Future<Map<String, CadRevision>> _currentRevisions(List<String> jobIds) async {
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
      // Newest seq first, so the first row seen for a job is the one that counts. A second would
      // mean two revisions both claim to be current, which is a bug rather than a state.
      out.putIfAbsent(revision.jobId, () => revision);
    }
    return out;
  }

  Future<Map<String, CadReview>> _latestReviews(List<String> revisionIds) async {
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

  /// The newest non-draft quote per job.
  Future<Map<String, Quote>> _quotesFor(List<String> jobIds) async {
    final rows = await guard(
      () => _client
          .from('quotes')
          .select('*, cost_lines(*)')
          .inFilter('job_id', jobIds)
          .inFilter('status', _visibleQuoteStatuses)
          .order('version', ascending: false),
    );
    final out = <String, Quote>{};
    for (final row in rows) {
      final quote = Quote.fromJson(row);
      out.putIfAbsent(quote.jobId, () => quote);
    }
    return out;
  }

  Future<Map<String, JobStage>> _waxStages(List<String> jobIds) async {
    final rows = await guard(
      () => _client
          .from('job_stages')
          .select()
          .inFilter('job_id', jobIds)
          .eq('stage', LifecycleStage.wax.wire)
          .inFilter('state', [StageState.active.wire, StageState.blocked.wire]),
    );
    final out = <String, JobStage>{};
    for (final row in rows) {
      final stage = JobStage.fromJson(row);
      out[stage.jobId] = stage;
    }
    return out;
  }

  Future<Map<String, AcceptanceCriteria>> _acceptanceFor(List<String> jobIds) async {
    final rows = await guard(
      () => _client.from('acceptance_criteria').select().inFilter('job_id', jobIds),
    );
    final out = <String, AcceptanceCriteria>{};
    for (final row in rows) {
      final criteria = AcceptanceCriteria.fromJson(row);
      out[criteria.jobId] = criteria;
    }
    return out;
  }

  /// The customer's own sign-off on the wax, read back off the immutable audit trail.
  Future<Map<String, ActivityEvent>> _waxDecisions(List<String> jobIds) async {
    final rows = await guard(
      () => _client
          .from('activity_events')
          .select()
          .inFilter('job_id', jobIds)
          .eq('stage', LifecycleStage.wax.wire)
          .inFilter('kind', [ActivityKind.approved.wire, ActivityKind.rejected.wire])
          .order('created_at', ascending: false),
    );
    final out = <String, ActivityEvent>{};
    for (final row in rows) {
      final event = ActivityEvent.fromJson(row);
      out.putIfAbsent(event.jobId, () => event);
    }
    return out;
  }

  Future<List<Attachment>> _rendersFor(Set<String> ids) async {
    if (ids.isEmpty) return const <Attachment>[];
    final rows = await guard(
      () => _client.from('attachments').select().inFilter('id', ids.toList()),
    );
    final files = [for (final row in rows) Attachment.fromJson(row)];
    return [for (final file in files) if (!file.isInternalOnly) file];
  }

  // -------------------------------------------------------------- the one write

  /// Record a customer decision on the immutable audit trail.
  ///
  /// D-005 is the reason this exists rather than a status column: `activity_events` has UPDATE and
  /// DELETE revoked in Postgres, so a sign-off written here cannot later be edited into something
  /// else. For a business taking custody of a client's diamonds, "who approved what, when" has to
  /// be reconstructible — and the mockups named "Client Portal" as an actor in exactly this feed
  /// while giving the client no way to become one.
  ///
  /// `events_insert` permits it: its check is `auth_can_see_job(job_id)`, which a customer passes
  /// for their own job.
  Future<ActivityEvent> recordDecision({
    required String jobId,
    required LifecycleStage stage,
    required bool approved,
    required String summary,
    String? detail,
    Map<String, dynamic> payload = const <String, dynamic>{},
  }) async {
    final row = await guard(
      () => _client
          .from('activity_events')
          .insert(<String, dynamic>{
            'job_id': jobId,
            // Convention 6: the enum crosses as its Postgres value, never `.name`.
            'kind': (approved ? ActivityKind.approved : ActivityKind.rejected).wire,
            'actor_id': _identity.requireUserId(),
            // D-008: the client's own name, off the session row. There is no other source and no
            // fallback literal.
            'actor_label': _identity.displayName,
            'stage': stage.wire,
            'summary': summary,
            'detail': detail?.trim(),
            'payload': payload,
          })
          .select()
          .single(),
    );
    return ActivityEvent.fromJson(row);
  }
}

// ================================================================= providers

@Riverpod(keepAlive: true)
PortalGateway portalGateway(Ref ref) => PortalGateway(
      ref.watch(supabaseProvider),
      ref.watch(attachmentStoreProvider),
      ref.watch(repoIdentityProvider),
    );

/// The session user's own customer id, or null for an internal operator.
///
/// D-008: this is `customer_users.customer_id`, which RLS restricts to `user_id = auth.uid()`.
/// The portal renders through it, which is why an internal user standing in `/portal` would see a
/// correct, permanent blank — and why the router sends them to work instead.
@Riverpod(keepAlive: true)
String? viewerCustomerId(Ref ref) =>
    ref.watch(currentUserProvider).value?.customerId;

/// The customer's orders, kept live. A stage moving is the whole reason a retailer opens this.
@riverpod
Stream<Live<List<PortalJobCard>>> portalJobsLive(Ref ref) async* {
  // Every dependency is watched before the first await: watching after one is how a provider ends
  // up subscribed to a dependency it no longer has a live element for.
  final client = ref.watch(supabaseProvider);
  final gateway = ref.watch(portalGatewayProvider);
  final viewer = await ref.watch(currentUserProvider.future);
  final customerId = viewer?.customerId;

  // An authenticated account with no `customer_users` row is a real state, not a bug: somebody
  // was invited and nobody linked them to a retailer. An empty list would read as "you have no
  // orders", which is a different and much worse lie — so it refuses and says what to do.
  if (customerId == null) {
    throw const PermissionDenied(
      message: 'Your sign-in is not linked to a retailer account yet, so there are no orders to '
          'show. Ask the workshop to connect it, then sign in again.',
      code: 'portal_no_customer',
    );
  }

  yield* liveQuery<List<PortalJobCard>>(
    client: client,
    channelName: 'portal-jobs:$customerId',
    tables: const [LiveTable(table: 'jobs'), LiveTable(table: 'job_stages')],
    read: () => gateway.jobs(customerId: customerId),
  );
}

/// One order. Not live: a customer reading their order does not need it reshuffling under them,
/// and every portal action invalidates this when it lands.
@riverpod
Future<PortalJobView> portalJobView(Ref ref, String jobId) =>
    ref.watch(portalGatewayProvider).jobView(jobId);

/// Everything waiting on the customer, across all their orders.
@riverpod
Future<PortalApprovals> portalApprovals(Ref ref) async {
  final gateway = ref.watch(portalGatewayProvider);
  final viewer = await ref.watch(currentUserProvider.future);
  final customerId = viewer?.customerId;
  // Same refusal as `portalJobsLive`: an unlinked account has no orders to decide about, and
  // "nothing to approve" would be a plausible-looking lie.
  if (customerId == null) {
    throw const PermissionDenied(
      message: 'Your sign-in is not linked to a retailer account yet. Ask the workshop to connect '
          'it, then sign in again.',
      code: 'portal_no_customer',
    );
  }
  return gateway.approvals(customerId: customerId);
}
