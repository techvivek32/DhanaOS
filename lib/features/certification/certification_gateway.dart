/// The certification read layer: the lab leg, its six real steps, and the audit trail behind them.
///
/// Three things the mockups declared and never wired are resolved here.
///
///  * **"Certification Required" was a toggle with nothing behind it.** Answering No has to skip
///    the `cert` stage *and* zero `delivery_schedules.cert_buffer_d`, because a delivery date that
///    still reserves three days for a lab that will never see the piece is wrong by three days.
///    `fn_complete_stage` reads `certificates.required` to do the skip; `SpecRepository` owns the
///    buffer. [CertBundle.bufferDisagrees] is what tells the screen the two have drifted apart.
///  * **The status stepper was six hardcoded nodes.** Here each node's state comes from
///    `certificates.status` and each node's timestamp comes from an `activity_events` row that was
///    actually written when that transition happened — which is also what makes the feed the
///    "Immutable Audit Trail" the mockup titled and did not have. UPDATE and DELETE are revoked on
///    that table, so the trail cannot be edited by anything in this app.
///  * **There was no SLA and no rejection.** `expected_back` is the date a lab can be chased
///    against, and [Certificate.isRejected] is a real terminal state with a reason attached
///    (D-006).
library;

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/data/repositories/customer_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/repositories/spec_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'certification_gateway.g.dart';

// ================================================================= the six steps

/// The lab leg as an operator describes it, which is six steps and not seven.
///
/// [CertStatus] has a seventh value, `rejected`, and it is deliberately **not** a node: a
/// rejection is not a further step along the road, it is the road stopping. It renders as the
/// grading node going red, which is where it actually happened.
enum CertStep {
  declared('Declared', 'The lab and the expected return date are on the job.'),
  sent('Sent', 'Out of the building, with a waybill against it.'),
  atLab('At the lab', 'Received and logged by the lab.'),
  grading('Grading', 'Under examination. Nothing to do but chase the date.'),
  certified('Certified', 'The report exists and its number is on the job.'),
  returned('Back in the shop', 'Piece and certificate both in hand.');

  const CertStep(this.label, this.blurb);

  final String label;
  final String blurb;

  /// The status a step corresponds to, for matching an audit event to a node.
  CertStatus get status => switch (this) {
        declared => CertStatus.waiting,
        sent => CertStatus.sent,
        atLab => CertStatus.atLab,
        grading => CertStatus.inProgress,
        certified => CertStatus.certified,
        returned => CertStatus.returned,
      };

  /// Where a status puts the trail.
  static CertStep of(CertStatus status) => switch (status) {
        CertStatus.waiting => declared,
        CertStatus.sent => sent,
        CertStatus.atLab => atLab,
        CertStatus.inProgress => grading,
        CertStatus.certified => certified,
        CertStatus.returned => returned,
        // A rejection happens while the lab has the piece, so the trail stops where it stopped.
        CertStatus.rejected => grading,
      };

  /// The statuses a plain "move it along" control may set from here.
  ///
  /// Forward-only: `certificates` records what a third party did, and a screen that walked it
  /// backwards would be inventing lab history.
  ///
  /// Two moves are deliberately **absent**, because each owes the record something a bare status
  /// change cannot carry:
  ///
  ///   * `declared → sent` needs the two dates, so `CertActions.sendToLab` owns it. Without them
  ///     there is no SLA and nothing to chase, which is the state every mockup shipped in.
  ///   * `grading → certified` needs the number and the report, so `CertActions.recordCertificate`
  ///     owns it. A leg marked certified with no number cannot close the stage anyway.
  List<CertStatus> get nextStatuses => switch (this) {
        declared => const <CertStatus>[],
        sent => const [CertStatus.atLab],
        atLab => const [CertStatus.inProgress],
        grading => const <CertStatus>[],
        certified => const [CertStatus.returned],
        returned => const <CertStatus>[],
      };
}

/// How one node of the stepper renders.
enum CertNodeState { done, active, blocked, pending }

/// One node, with the fact behind it.
final class CertNode {
  const CertNode({
    required this.step,
    required this.state,
    this.at,
    this.actor,
    this.note,
  });

  final CertStep step;
  final CertNodeState state;

  /// When it actually happened, from the audit event or from the certificate's own date column.
  /// Null means nothing recorded it, which is honest — the mockup stamped every node.
  final DateTime? at;

  /// `activity_events.actor_label` — the operator's own name, never a literal (D-008).
  final String? actor;

  /// The lab's objection, on the node where the trail stopped.
  final String? note;

  bool get isDone => state == CertNodeState.done;
  bool get isActive => state == CertNodeState.active;
  bool get isBlocked => state == CertNodeState.blocked;
  bool get isPending => state == CertNodeState.pending;

  /// Both done and blocked have been reached; only pending has not.
  bool get isReached => state != CertNodeState.pending;
}

// ================================================================= audit event

/// One `activity_events` row about this job's certification.
///
/// Read directly rather than through the digital-thread view because the node timestamps are
/// matched by `payload->>'cert_status'`, which the view does not expose. Prose is not a
/// discriminator: "Sent to IGI" and "Sent back to IGI" are two transitions and one substring.
final class CertEvent {
  const CertEvent({
    required this.id,
    required this.summary,
    required this.createdAt,
    this.detail,
    this.actorLabel,
    this.status,
  });

  factory CertEvent.fromRow(Map<String, dynamic> row) {
    final payload = row['payload'];
    final wire = payload is Map<String, dynamic> ? payload['cert_status'] : null;
    return CertEvent(
      id: row['id'] as String,
      summary: row['summary'] as String,
      detail: row['detail'] as String?,
      actorLabel: row['actor_label'] as String?,
      // Convention 6: the enum crosses back through `parse`, never through an index.
      status: wire is String ? CertStatus.parse(wire) : null,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  final String id;
  final String summary;
  final String? detail;
  final String? actorLabel;

  /// Which transition this row records, when it records one.
  final CertStatus? status;

  final DateTime createdAt;

  String get actorDisplay => actorLabel ?? 'System';
}

// ================================================================= the bundle

/// Everything `/certification/<jobId>` renders.
final class CertBundle {
  const CertBundle({
    required this.job,
    required this.rail,
    required this.certificate,
    required this.history,
    required this.acceptance,
    required this.delivery,
    required this.labs,
    required this.pdf,
    required this.pdfUrl,
    required this.events,
    required this.openException,
  });

  final Job job;

  /// D-005: closing or skipping the cert stage is a rail move, so the rail decides where the job
  /// actually is.
  final StageRail rail;

  /// The current lab leg, or null before anyone declared one.
  final Certificate? certificate;

  /// Every certificate row on the job, newest first. A resubmission after a rejection is a new
  /// leg on the same piece.
  final List<Certificate> history;

  /// Where the lab was chosen at intake. `acceptance_criteria.cert_lab = none` is the other half
  /// of "certification not required".
  final AcceptanceCriteria? acceptance;

  /// Carries `cert_buffer_d`, the days reserved in the delivery plan for the lab.
  final DeliverySchedule? delivery;

  /// Active partners of kind `lab`. D-002 allows a partner on casting and certification only.
  final List<Partner> labs;

  final Attachment? pdf;

  /// A short-lived signed URL. Signed, never public — a public URL to a customer's certificate
  /// outlives the job and the relationship.
  final String? pdfUrl;

  /// The certification audit trail, newest first.
  final List<CertEvent> events;

  /// An open `job_exceptions` row on the cert stage — what a lab rejection raises, and what holds
  /// the stage `blocked` until it is resolved.
  final JobException? openException;

  JobStage? get certStage => rail.stageFor(LifecycleStage.cert);

  bool get isStageActive => certStage?.isActive ?? false;

  bool get isStageBlocked => certStage?.isBlocked ?? false;

  bool get isStageSkipped => certStage?.isSkipped ?? false;

  bool get isStageClosed => certStage?.isClosed ?? false;

  /// The rail row a completion closes, or null when the job is not standing at certification.
  JobStage? get stageToClose {
    final active = rail.activeStage;
    return active != null && active.stage == LifecycleStage.cert ? active : null;
  }

  /// Whether the job needs a lab at all. Before a certificate row exists this falls back to what
  /// was agreed at intake, so the screen opens with the right answer rather than a default Yes.
  bool get isRequired {
    final cert = certificate;
    if (cert != null) return cert.isRequired && !cert.lab.skipsStage;
    final agreed = acceptance;
    return agreed == null || !agreed.skipsCertification;
  }

  /// The lab to show, from the certificate if one exists, otherwise from the intake agreement.
  CertLab get lab =>
      certificate?.lab ?? acceptance?.certLab ?? CertLab.igi;

  String get labLabel {
    final cert = certificate;
    if (cert == null) return acceptance?.certLabLabel ?? lab.label;
    if (cert.lab == CertLab.other) {
      // `certificates` has no free-text lab name; the one the operator typed lives on the
      // acceptance row, which is where the intake wizard asked for it.
      final named = acceptance?.certLabOther?.trim();
      return named == null || named.isEmpty ? 'Other' : named;
    }
    return cert.lab.label;
  }

  Partner? get labPartner {
    final id = certificate?.labPartnerId;
    return id == null ? null : labs.firstWhereOrNull((p) => p.id == id);
  }

  CertStatus get status => certificate?.status ?? CertStatus.waiting;

  CertStep get step => CertStep.of(status);

  /// The cross-screen dependency, stated as something the screen can act on: choosing no lab must
  /// zero the certification buffer, and a mismatch means one of the two writes did not land.
  bool get bufferDisagrees {
    final plan = delivery;
    if (plan == null) return false;
    return !plan.certBufferAgreesWith(isRequired ? lab : CertLab.none);
  }

  int get certBufferDays => delivery?.certBufferD ?? 0;

  /// The six nodes, each carrying the real fact behind it.
  List<CertNode> get nodes {
    final cert = certificate;
    if (cert == null) {
      return [
        for (final step in CertStep.values)
          CertNode(step: step, state: CertNodeState.pending),
      ];
    }

    final current = CertStep.of(cert.status);
    final rejected = cert.isRejected;

    return [
      for (final step in CertStep.values)
        CertNode(
          step: step,
          state: _stateOf(step, current: current, rejected: rejected),
          at: _timestampFor(step, cert),
          actor: eventFor(step)?.actorLabel,
          note: rejected && step == current ? cert.rejectionNote : null,
        ),
    ];
  }

  CertNodeState _stateOf(
    CertStep step, {
    required CertStep current,
    required bool rejected,
  }) {
    if (step.index < current.index) return CertNodeState.done;
    if (step.index > current.index) return CertNodeState.pending;
    if (rejected) return CertNodeState.blocked;
    // The last node is an end, not a wait.
    return step == CertStep.returned ? CertNodeState.done : CertNodeState.active;
  }

  /// When a step happened. The audit event is the authority; the certificate's own date columns
  /// stand in for the two steps that have one, so a leg recorded before this screen existed still
  /// renders its dates.
  DateTime? _timestampFor(CertStep step, Certificate cert) {
    final logged = eventFor(step)?.createdAt;
    if (logged != null) return logged;
    return switch (step) {
      CertStep.declared => cert.createdAt,
      CertStep.sent => cert.sentAt,
      _ => null,
    };
  }

  /// The event that recorded a step, oldest-first so a resubmitted leg shows the first time it
  /// reached that step rather than the latest.
  CertEvent? eventFor(CertStep step) => events
      .sorted((a, b) => a.createdAt.compareTo(b.createdAt))
      .firstWhereOrNull((event) => event.status == step.status);

  /// What still has to arrive before the stage can close.
  List<String> get outstanding => certificate?.outstanding ?? const <String>[];

  /// Both the number and the PDF are in hand.
  bool get isComplete => certificate?.isComplete ?? false;

  bool get isRejected => certificate?.isRejected ?? false;

  bool get isOverdue => certificate?.isOverdue ?? false;

  /// Days until the promised return, negative when the lab is late. Null with no SLA — which is
  /// the state every mockup shipped in, because none of them had the field.
  int? get daysToReturn {
    final due = certificate?.expectedBack;
    if (due == null) return null;
    final today = DateTime.now();
    return DateTime(due.year, due.month, due.day)
        .difference(DateTime(today.year, today.month, today.day))
        .inDays;
  }

  /// The certification stage can be closed: either the certificate is in hand, or no lab was ever
  /// required.
  bool get canCloseStage {
    if (!isStageActive && !isStageBlocked) return false;
    if (isRejected) return false;
    return !isRequired || isComplete;
  }

  /// Why closing is held shut, phrased for whoever is looking at the button.
  String? get closeBlockedReason {
    if (isStageClosed) return null;
    if (!isStageActive && !isStageBlocked) {
      final active = rail.activeStage;
      return active == null
          ? 'This job has no active stage, so there is no certification stage to close.'
          : 'The job is at ${active.stage.label}, not Certification.';
    }
    if (isRejected) {
      return 'The lab rejected the piece. Correct it and resubmit, or mark certification as not '
          'required — the stage cannot close on a rejection.';
    }
    if (isRequired && !isComplete) {
      final missing = outstanding;
      return missing.isEmpty
          ? 'The certificate is not in hand yet.'
          : 'Still missing: ${missing.join(' and ')}.';
    }
    return null;
  }

  /// A certificate leg exists at all.
  bool get hasLeg => certificate != null;

  /// The statuses the operator may advance to from here.
  List<CertStatus> get nextStatuses =>
      isRejected ? const <CertStatus>[] : step.nextStatuses;

  String get nextStageLabel => rail.nextStage?.stage.label ?? LifecycleStage.dispatch.label;
}

// ================================================================= gateway

final class CertGateway {
  const CertGateway(
    this._client,
    this._identity,
    this._store,
    this._jobs,
    this._specs,
    this._production,
    this._directory,
  );

  final SupabaseClient _client;
  final RepoIdentity _identity;
  final AttachmentStore _store;
  final JobRepository _jobs;
  final SpecRepository _specs;
  final ProductionRepository _production;
  final CustomerRepository _directory;

  /// Only the columns a node and a feed row need. `payload` is in because it carries the
  /// `cert_status` a node is matched by.
  static const _eventColumns = 'id, summary, detail, actor_label, payload, created_at';

  /// Everything the screen renders.
  ///
  /// Sequential on purpose: a parallel `.wait` would replace a [DhFailure] — which carries the
  /// server's own operator-facing sentence — with a `ParallelWaitError`.
  Future<CertBundle> bundle(String jobId) async {
    final snapshot = await _jobs.getSnapshot(jobId);
    final history = await _production.certificates(jobId);
    final acceptance = await _specs.getAcceptance(jobId);
    final delivery = await _specs.getDelivery(jobId);
    final labs = await _directory.listPartners(kind: PartnerKind.lab);
    final events = await certEvents(jobId);

    final current = history.firstOrNull;
    final pdfId = current?.pdfId;
    Attachment? pdf;
    String? pdfUrl;
    if (pdfId != null) {
      pdf = await _attachment(pdfId);
      if (pdf != null) {
        // A file that will not sign is absent rather than fatal — the number is still readable.
        final urls = await _store.signedUrls([pdf]);
        pdfUrl = urls[pdf.id];
      }
    }

    return CertBundle(
      job: snapshot.job,
      rail: snapshot.rail,
      certificate: current,
      history: history,
      acceptance: acceptance,
      delivery: delivery,
      labs: labs,
      pdf: pdf,
      pdfUrl: pdfUrl,
      events: events,
      openException: snapshot.openExceptions
          .firstWhereOrNull((e) => e.stage == LifecycleStage.cert),
    );
  }

  /// The certification audit trail, newest first.
  Future<List<CertEvent>> certEvents(String jobId) async {
    final rows = await guard(
      () => _client
          .from('activity_events')
          .select(_eventColumns)
          .eq('job_id', jobId)
          .eq('stage', LifecycleStage.cert.wire)
          .order('created_at', ascending: false)
          .limit(100),
    );
    return [for (final row in rows) CertEvent.fromRow(row)];
  }

  /// Write the transition to the append-only log.
  ///
  /// D-005: `certificates` is a mutable row — it has to be, because a lab's own status changes —
  /// so the *history* of the leg only exists if each move is logged as it happens. UPDATE and
  /// DELETE are revoked on `activity_events`, which is what makes this trail evidence rather than
  /// a list. `cert_status` goes into `payload` so a node is matched by value and not by parsing
  /// its own summary line.
  Future<void> logTransition({
    required String jobId,
    required String summary,
    CertStatus? status,
    String? detail,
    ActivityKind kind = ActivityKind.system,
  }) async {
    await guard(
      () => _client.from('activity_events').insert(<String, Object?>{
        'job_id': jobId,
        'kind': kind.wire,
        'actor_id': _identity.userId,
        // D-008: the operator's own name off their `app_users` row, never a literal.
        'actor_label': _identity.displayName,
        'stage': LifecycleStage.cert.wire,
        'summary': summary,
        'detail': detail,
        if (status != null) 'payload': <String, Object?>{'cert_status': status.wire},
      }),
    );
  }

  Future<Attachment?> _attachment(String id) async {
    final row = await guardOrNull(
      () => _client.from('attachments').select().eq('id', id).maybeSingle(),
    );
    return row == null ? null : Attachment.fromJson(row);
  }
}

// ================================================================= providers

@Riverpod(keepAlive: true)
CertGateway certGateway(Ref ref) => CertGateway(
      ref.watch(supabaseProvider),
      ref.watch(repoIdentityProvider),
      ref.watch(attachmentStoreProvider),
      ref.watch(jobRepositoryProvider),
      ref.watch(specRepositoryProvider),
      ref.watch(productionRepositoryProvider),
      ref.watch(customerRepositoryProvider),
    );

/// One lab leg, re-read on demand.
///
/// Not live: a certificate number is typed off a paper report, and a screen that re-sorts itself
/// mid-entry is worse than one that needs a pull to refresh. Every certification action
/// invalidates this when it lands.
@riverpod
Future<CertBundle> certBundle(Ref ref, String jobId) =>
    ref.watch(certGatewayProvider).bundle(jobId);
