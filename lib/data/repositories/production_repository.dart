/// Typed data access for the shop floor: CAD, casting, bench measurement, QC, certification
/// and shipping.
///
/// Three of the four D-011 rules pass through this file, and the split of responsibility is
/// deliberate everywhere:
///
///  * **Rule 1 — casting evidence.** [ProductionRepository.attachCastingPhoto] is what makes
///    `casting_params.photo_id` non-null, which is what flips [CastingParams.canComplete] and
///    what `fn_complete_stage` checks before it will close the stage.
///  * **Rule 2 — asymmetric CAD decision.** The `cad_reject_needs_comment` CHECK on
///    `cad_reviews` is the rule. [ProductionRepository.submitCadReview] sends the row and lets
///    Postgres refuse it; all this file adds is a translation of the constraint *name* into the
///    sentence the domain model already owns ([CadReview.rejectionNeedsComment]), because
///    Postgres's own wording for a CHECK violation is `violates check constraint "…"` and that
///    is not a sentence an operator can act on. The rule itself is never re-implemented here.
///  * **Rule 3 — QC completeness.** [ProductionRepository.authorizeQc] refuses on
///    [QcInspection.canAuthorize], because `qc_inspections` has no constraint that would stop
///    an `authorized_at` being written under an unfinished checklist — `fn_complete_stage`
///    guards the *stage advance*, which is the consequential act, and this guards the signature.
///
/// The dispatch gate is the opposite case and is left alone on purpose: `fn_dispatch_shipment`
/// raises a message already written from the operator's side ("Complete the security protocol
/// first — 2 check(s) outstanding"), so [ProductionRepository.dispatchShipment] surfaces it
/// verbatim. [Shipment.canDispatch] is what holds the button shut; the RPC is what holds the
/// data shut.
///
/// Stage transitions are NOT here. Moving a job is `fn_complete_stage` (D-005), which the job
/// repository owns; this file records what happened *at* a stage.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'production_repository.g.dart';

/// `date` columns (`certificates.sent_at`, `expected_back`) take a calendar day, not an
/// instant. Sending a UTC timestamp for one shifts the date by a day for half the clock, so
/// these are written from the operator's own Y-M-D.
final _wireDate = DateFormat('yyyy-MM-dd');

// ---------------------------------------------------------------- request payloads

/// A file on its way into a bucket, before it knows which job or kind it belongs to.
///
/// The repository owns the routing (which bucket, which `AttachmentKind`, which foreign key it
/// lands on), so a caller only has to hand over bytes or a path. `image_picker` gives a path;
/// a camera capture or a canvas signature gives bytes.
final class FileUpload {
  FileUpload.bytes({required this.filename, required this.bytes, this.caption})
      : file = null;

  FileUpload.file(File source, {String? filename, this.caption})
      : file = source,
        bytes = null,
        filename = filename ?? source.path.split(RegExp(r'[\\/]')).last;

  /// The name an operator recognises — `cast_tree_dh_2026_01842.jpg`.
  final String filename;

  /// Shown under the thumbnail. A casting photo with no caption is still evidence; a caption
  /// makes it findable.
  final String? caption;

  /// Exactly one of these is set. Bytes go up through `uploadBinary`; a file is streamed, which
  /// matters for a certificate PDF on a cheap handset.
  final Uint8List? bytes;
  final File? file;

  UploadRequest _toRequest({
    required String orgId,
    required AttachmentKind kind,
    String? jobId,
  }) {
    final data = bytes;
    if (data != null) {
      return UploadRequest.bytes(
        orgId: orgId,
        kind: kind,
        jobId: jobId,
        filename: filename,
        bytes: data,
        caption: caption,
      );
    }
    return UploadRequest.file(
      orgId: orgId,
      kind: kind,
      jobId: jobId,
      file: file!,
      filename: filename,
      caption: caption,
    );
  }
}

/// One line to seed a QC checklist with.
///
/// Built from [AcceptanceCriteria.checklistLabels], so the inspection a piece is measured
/// against is the one that was agreed at intake rather than a list the inspector invents.
/// [requirementId] is the D-009 citation that lets QC, the bench and the customer all point at
/// the same spec line.
final class QcSeedItem {
  const QcSeedItem(this.label, {this.helper, this.requirementId});

  /// 'Metal weight and size verified'.
  final String label;

  /// 'Target: 4.8g Pt950. Allowable variance: ±0.2g.'
  final String? helper;

  final String? requirementId;
}

/// One step of a tamper-seal protocol to seed a shipment with.
final class SecurityCheckSeed {
  const SecurityCheckSeed(this.label, {this.reference});

  /// 'Tamper-evident seal applied to inner box'.
  final String label;

  /// 'Seal #TE-921' — prefilled only when the serial is known in advance; normally the operator
  /// types it as they apply the seal.
  final String? reference;
}

// ---------------------------------------------------------------- repository

final class ProductionRepository {
  const ProductionRepository(this._client, this._identity, this._files);

  final SupabaseClient _client;

  /// D-008: `org_id` and the actor come from the signed-in operator's `app_users` row and from
  /// nowhere else. A repository never invents either.
  final RepoIdentity _identity;

  final AttachmentStore _files;

  /// Inspections come back with their checklist already ordered, so no screen has to sort
  /// before it can render the 5/5 counter.
  static const _inspectionSelect = '*, qc_checklist_items(*)';

  /// A leg and its security protocol travel together — the dispatch button needs both.
  static const _shipmentSelect = '*, shipment_checks(*)';

  /// The protocol `shipping_dispatch` drew. Its JavaScript toggled opacity classes and never
  /// set `.disabled`, so the piece could be dispatched with none of these done;
  /// `fn_dispatch_shipment` now refuses while any row is outstanding.
  static const defaultSecurityProtocol = <SecurityCheckSeed>[
    SecurityCheckSeed('Tamper-evident seal applied to inner box'),
    SecurityCheckSeed('Piece photographed in final packaging'),
    SecurityCheckSeed('Contents and carat weight verified against the job card'),
  ];

  String get _org => _identity.requireOrgId();

  /// The signed-in operator, for the `*_by` columns. A record of who authorised QC or closed a
  /// stage is the whole point of D-005, so an unauthenticated write is refused rather than
  /// attributed to nobody.
  String get _actor => _identity.requireUserId();

  // -------------------------------------------------------------- CAD revisions

  /// Newest first, which is the order `cad_review` presented versions in.
  Future<List<CadRevision>> cadRevisions(String jobId) async {
    final rows = await guard(
      () => _client
          .from('cad_revisions')
          .select()
          .eq('job_id', jobId)
          .order('seq', ascending: false),
    );
    return [for (final row in rows) CadRevision.fromJson(row)];
  }

  /// The revision on the table right now.
  Future<CadRevision?> currentCadRevision(String jobId) async {
    final row = await guard(
      () => _client
          .from('cad_revisions')
          .select()
          .eq('job_id', jobId)
          .eq('is_current', true)
          .order('seq', ascending: false)
          .limit(1)
          .maybeSingle(),
    );
    return row == null ? null : CadRevision.fromJson(row);
  }

  /// Offer a new version.
  ///
  /// Two writes, in this order: the previous revisions stop being current, then the new row
  /// goes in. If the insert is refused the worst case is a job with no current revision, which
  /// reads as "nothing to review" — the opposite order would leave two rows both claiming to be
  /// the design of record.
  Future<CadRevision> createCadRevision({
    required String jobId,
    required String version,
    String? designerNote,
    List<String> renderIds = const <String>[],
    String? modelId,
    Map<String, dynamic> specDiff = const <String, dynamic>{},
  }) async {
    final existing = await cadRevisions(jobId);
    final nextSeq = existing.isEmpty ? 1 : existing.first.seq + 1;

    if (existing.isNotEmpty) {
      await guard(
        () => _client
            .from('cad_revisions')
            .update(<String, dynamic>{'is_current': false})
            .eq('job_id', jobId)
            .eq('is_current', true),
      );
    }

    final row = await guard(
      () => _client
          .from('cad_revisions')
          .insert(<String, dynamic>{
            'job_id': jobId,
            'version': version.trim(),
            'seq': nextSeq,
            'designer_id': _actor,
            'designer_note': designerNote?.trim(),
            'render_ids': renderIds,
            'model_id': modelId,
            'is_current': true,
            'spec_diff': specDiff,
          })
          .select()
          .single(),
    );
    return CadRevision.fromJson(row);
  }

  /// Attach renders or the mesh after the revision row exists — a designer uploads the STL
  /// minutes after the render, and a caster cannot start from a render ([CadRevision.hasModel]).
  Future<CadRevision> updateCadRevisionFiles({
    required String revisionId,
    List<String>? renderIds,
    String? modelId,
    Map<String, dynamic>? specDiff,
    String? designerNote,
  }) async {
    final values = <String, dynamic>{
      if (renderIds != null) 'render_ids': renderIds,
      if (modelId != null) 'model_id': modelId,
      if (specDiff != null) 'spec_diff': specDiff,
      if (designerNote != null) 'designer_note': designerNote.trim(),
    };
    if (values.isEmpty) return _readCadRevision(revisionId);

    final row = await guard(
      () => _client
          .from('cad_revisions')
          .update(values)
          .eq('id', revisionId)
          .select()
          .single(),
    );
    return CadRevision.fromJson(row);
  }

  Future<CadRevision> _readCadRevision(String revisionId) async {
    final row = await guard(
      () => _client.from('cad_revisions').select().eq('id', revisionId).single(),
    );
    return CadRevision.fromJson(row);
  }

  // -------------------------------------------------------------- CAD annotations

  /// Pins on a render, oldest first — a review reads as a conversation down the image.
  Future<List<CadAnnotation>> cadAnnotations(
    String revisionId, {
    bool openOnly = false,
  }) async {
    final rows = await guard(() {
      final query = _client.from('cad_annotations').select().eq('revision_id', revisionId);
      final scoped = openOnly ? query.isFilter('resolved_at', null) : query;
      return scoped.order('created_at', ascending: true);
    });
    return [for (final row in rows) CadAnnotation.fromJson(row)];
  }

  /// Drop a pin. Coordinates are percentages so the same pin lands correctly on a phone and on
  /// a workstation.
  Future<CadAnnotation> addCadAnnotation({
    required String revisionId,
    required double xPct,
    required double yPct,
    required String body,
  }) async {
    final text = body.trim();
    if (text.isEmpty) {
      throw const RuleViolation(
        message: 'Type what needs to change before dropping the pin. A pin with no note tells '
            'the designer where to look and nothing else.',
        code: 'annotation_empty',
      );
    }
    final row = await guard(
      () => _client
          .from('cad_annotations')
          .insert(<String, dynamic>{
            'revision_id': revisionId,
            'x_pct': xPct,
            'y_pct': yPct,
            'body': text,
            'author_id': _actor,
          })
          .select()
          .single(),
    );
    return CadAnnotation.fromJson(row);
  }

  Future<CadAnnotation> resolveCadAnnotation(String annotationId) async {
    final row = await guard(
      () => _client
          .from('cad_annotations')
          .update(<String, dynamic>{'resolved_at': _now()})
          .eq('id', annotationId)
          .select()
          .single(),
    );
    return CadAnnotation.fromJson(row);
  }

  // -------------------------------------------------------------- CAD reviews

  Future<List<CadReview>> cadReviews(String revisionId) async {
    final rows = await guard(
      () => _client
          .from('cad_reviews')
          .select()
          .eq('revision_id', revisionId)
          .order('created_at', ascending: false),
    );
    return [for (final row in rows) CadReview.fromJson(row)];
  }

  /// D-011 rule 2, decided in Postgres.
  ///
  /// The `cad_reject_needs_comment` CHECK is the rule: approve freely, reject with a reason.
  /// This method does not pre-empt it — an empty comment is sent and refused, so the rule cannot
  /// be weakened by a client rewrite. What it does do is replace Postgres's `violates check
  /// constraint "cad_reject_needs_comment"` with [CadReview.rejectionNeedsComment], which is the
  /// same rule in words the designer's reviewer can act on. Bind the button's enabled state to
  /// [CadReview.canSubmit] so the operator normally never sees either.
  ///
  /// An approval locks the revision: a customer who approved v2.0 must not later be shown a
  /// changed v2.0.
  Future<CadReview> submitCadReview({
    required String revisionId,
    required bool approved,
    String? comment,
  }) async {
    final row = await _translateConstraint(
      () => _client
          .from('cad_reviews')
          .insert(<String, dynamic>{
            'revision_id': revisionId,
            'reviewer_id': _actor,
            'approved': approved,
            'comment': comment?.trim(),
          })
          .select()
          .single(),
      constraint: 'cad_reject_needs_comment',
      message: CadReview.rejectionNeedsComment,
    );

    if (approved) {
      await guard(
        () => _client
            .from('cad_revisions')
            .update(<String, dynamic>{'is_locked': true})
            .eq('id', revisionId),
      );
    }
    return CadReview.fromJson(row);
  }

  // -------------------------------------------------------------- casting

  Future<CastingParams?> castingParams(String jobId) async {
    final row = await guard(
      () => _client.from('casting_params').select().eq('job_id', jobId).maybeSingle(),
    );
    return row == null ? null : CastingParams.fromJson(row);
  }

  /// Save the caster's brief. The casting form owns this row, so every field it edits is
  /// written — including back to null when the operator clears one.
  ///
  /// `photo_id` and `completed_at` are deliberately absent: the photo is set by
  /// [attachCastingPhoto] and the completion by `fn_complete_stage`, and a form save must never
  /// be able to drop the evidence D-011 rule 1 depends on.
  Future<CastingParams> saveCastingParams({
    required String jobId,
    String? partnerId,
    String? alloy,
    int? flaskTempC,
    int? metalTempC,
    double? treeWeightG,
    DateTime? receivedAt,
    DateTime? expectedAt,
    String? notes,
  }) async {
    final row = await guard(
      () => _client
          .from('casting_params')
          .upsert(
            <String, dynamic>{
              'job_id': jobId,
              'partner_id': partnerId,
              'alloy': alloy?.trim(),
              'flask_temp_c': flaskTempC,
              'metal_temp_c': metalTempC,
              'tree_weight_g': treeWeightG,
              'received_at': _tsOrNull(receivedAt),
              'expected_at': _tsOrNull(expectedAt),
              'notes': notes?.trim(),
            },
            onConflict: 'job_id',
          )
          .select()
          .single(),
    );
    return CastingParams.fromJson(row);
  }

  /// D-011 rule 1 — the single best idea in the corpus.
  ///
  /// `caster_dashboard` shipped "Mark Complete" disabled behind a mandatory `accept="image/*"`
  /// upload. This is the write that satisfies it. The row is upserted rather than updated so a
  /// caster can photograph the tree before anyone has filled in the flask temperatures —
  /// evidence must never be blocked on paperwork.
  ///
  /// Returns the refreshed params, so the caller can read [CastingParams.canComplete] straight
  /// off the result instead of refetching.
  Future<CastingParams> attachCastingPhoto({
    required String jobId,
    required FileUpload photo,
  }) async {
    final attachment = await _upload(
      photo,
      jobId: jobId,
      kind: AttachmentKind.castingPhoto,
    );
    final row = await guard(
      () => _client
          .from('casting_params')
          .upsert(
            <String, dynamic>{'job_id': jobId, 'photo_id': attachment.id},
            onConflict: 'job_id',
          )
          .select()
          .single(),
    );
    return CastingParams.fromJson(row);
  }

  // `job_exceptions` — `caster_dashboard`'s "Report Issue" — is `JobRepository`'s: raising one
  // also flips the stage to `blocked`, which is stage movement and therefore D-005's business,
  // not this file's. Use `JobRepository.raiseException` / `resolveException` / `listExceptions`.

  // -------------------------------------------------------------- bench measurements

  Future<List<StageMeasurement>> measurements(
    String jobId, {
    LifecycleStage? stage,
  }) async {
    final rows = await guard(() {
      final query = _client.from('stage_measurements').select().eq('job_id', jobId);
      final scoped = stage == null ? query : query.eq('stage', stage.wire);
      return scoped.order('created_at', ascending: false);
    });
    return [for (final row in rows) StageMeasurement.fromJson(row)];
  }

  /// What the bench actually weighed. No screen in the mockups captured a production
  /// measurement; `order_details` showed the binding spec as read-only while a note in the same
  /// thread said "Update spec sheet".
  ///
  /// [targetG] and [toleranceG] are copied from the spec at measurement time on purpose, so a
  /// later spec change cannot retroactively turn a passed measurement into a failed one.
  /// `within_tol` is a generated column and is never written.
  ///
  /// [scrapG] records the loss; putting that loss against a metal item in the vault is
  /// `InventoryRepository.scrap`, because the ledger is the inventory repository's business.
  Future<StageMeasurement> recordMeasurement({
    required String jobId,
    required LifecycleStage stage,
    double? weightG,
    double? targetG,
    double? toleranceG,
    double? scrapG,
    String? notes,
    String? photoId,
  }) async {
    final row = await guard(
      () => _client
          .from('stage_measurements')
          .insert(<String, dynamic>{
            'job_id': jobId,
            'stage': stage.wire,
            'measured_by': _actor,
            'weight_g': weightG,
            'target_g': targetG,
            'tolerance_g': toleranceG,
            'scrap_g': scrapG,
            'notes': notes?.trim(),
            'photo_id': photoId,
          })
          .select()
          .single(),
    );
    return StageMeasurement.fromJson(row);
  }

  // -------------------------------------------------------------- QC

  /// Every attempt, newest first. D-006: a reinspection after rework is its own attempt rather
  /// than an overwrite of the failure.
  Future<List<QcInspection>> qcInspections(String jobId) async {
    final rows = await guard(
      () => _client
          .from('qc_inspections')
          .select(_inspectionSelect)
          .eq('job_id', jobId)
          .order('attempt', ascending: false)
          .order('position', ascending: true, referencedTable: 'qc_checklist_items'),
    );
    return [for (final row in rows) QcInspection.fromJson(row)];
  }

  Future<QcInspection?> latestQcInspection(String jobId) async {
    final row = await guard(
      () => _client
          .from('qc_inspections')
          .select(_inspectionSelect)
          .eq('job_id', jobId)
          .order('attempt', ascending: false)
          .order('position', ascending: true, referencedTable: 'qc_checklist_items')
          .limit(1)
          .maybeSingle(),
    );
    return row == null ? null : QcInspection.fromJson(row);
  }

  Future<QcInspection> qcInspection(String inspectionId) async {
    final row = await guard(
      () => _client
          .from('qc_inspections')
          .select(_inspectionSelect)
          .eq('id', inspectionId)
          .order('position', ascending: true, referencedTable: 'qc_checklist_items')
          .single(),
    );
    return QcInspection.fromJson(row);
  }

  /// Open an inspection and seed its checklist.
  ///
  /// [checklist] comes from [AcceptanceCriteria.checklistLabels], so the piece is measured
  /// against what was agreed at intake. An inspection with no items can never be authorised
  /// (D-011 rule 3 requires a *full* checklist and reads an empty one as unfinished), so an
  /// empty seed is refused here rather than producing a QC screen with a permanently dead
  /// button.
  ///
  /// [cadRevisionId] is not decoration: "Matches approved CAD" is meaningless without naming
  /// which CAD.
  Future<QcInspection> openQcInspection({
    required String jobId,
    required List<QcSeedItem> checklist,
    QualityAuthority authority = QualityAuthority.internalQc,
    String? cadRevisionId,
  }) async {
    if (checklist.isEmpty) {
      throw const RuleViolation(
        message: 'Build the acceptance checklist first. QC cannot authorise a piece against an '
            'empty list.',
        code: 'checklist_empty',
      );
    }

    final previous = await guard(
      () => _client
          .from('qc_inspections')
          .select('attempt')
          .eq('job_id', jobId)
          .order('attempt', ascending: false)
          .limit(1)
          .maybeSingle(),
    );
    final attempt = (previous?['attempt'] as int? ?? 0) + 1;

    final inspection = await guard(
      () => _client
          .from('qc_inspections')
          .insert(<String, dynamic>{
            'job_id': jobId,
            'attempt': attempt,
            'status': QcStatus.inProgress.wire,
            'inspector_id': _actor,
            'authority': authority.wire,
            'cad_revision_id': cadRevisionId,
          })
          .select('id')
          .single(),
    );
    final inspectionId = inspection['id'] as String;

    await guard(
      () => _client.from('qc_checklist_items').insert(<Map<String, dynamic>>[
        for (var i = 0; i < checklist.length; i++)
          <String, dynamic>{
            'inspection_id': inspectionId,
            'position': i + 1,
            'label': checklist[i].label,
            'helper': checklist[i].helper,
            'requirement_id': checklist[i].requirementId,
          },
      ]),
    );

    return qcInspection(inspectionId);
  }

  /// Answer one line. Three states, not two: null clears the answer back to "not yet checked",
  /// which is what an inspector needs when they tick the wrong row.
  ///
  /// Returns the whole inspection so the authorisation button re-evaluates
  /// [QcInspection.canAuthorize] off the same read.
  Future<QcInspection> setQcCheck({
    required String inspectionId,
    required String itemId,
    required bool? passed,
    String? evidenceId,
  }) async {
    await guard(
      () => _client
          .from('qc_checklist_items')
          .update(<String, dynamic>{
            'passed': passed,
            'checked_by': passed == null ? null : _actor,
            'checked_at': passed == null ? null : _now(),
            if (evidenceId != null) 'evidence_id': evidenceId,
          })
          .eq('id', itemId)
          .eq('inspection_id', inspectionId),
    );
    return qcInspection(inspectionId);
  }

  /// The file input the mockup's "inspection evidence" dropzone never had. Routed to the
  /// `vault` bucket by [AttachmentKind.qcEvidence] — evidence behind an irreversible
  /// authorisation is not customer-facing.
  Future<QcInspection> attachQcEvidence({
    required String inspectionId,
    required String itemId,
    required String jobId,
    required FileUpload evidence,
  }) async {
    final attachment = await _upload(
      evidence,
      jobId: jobId,
      kind: AttachmentKind.qcEvidence,
    );
    await guard(
      () => _client
          .from('qc_checklist_items')
          .update(<String, dynamic>{'evidence_id': attachment.id})
          .eq('id', itemId)
          .eq('inspection_id', inspectionId),
    );
    return qcInspection(inspectionId);
  }

  /// D-011 rule 3 — authorisation enables only at a full checklist.
  ///
  /// The checklist is re-read from the server before the signature is written, because the
  /// inspection may have been open on this device for twenty minutes while someone else
  /// reopened a line. `qc_inspections` carries no constraint that would stop an `authorized_at`
  /// under an unfinished list — `fn_complete_stage` guards the stage advance, and this guards
  /// the signature — so the refusal is stated here, in the words
  /// [QcInspection.authorizationBlockedReason] already owns.
  Future<QcInspection> authorizeQc(String inspectionId) async {
    final current = await qcInspection(inspectionId);
    if (current.isAuthorized) return current;
    if (!current.canAuthorize) {
      throw RuleViolation(
        message: current.authorizationBlockedReason ??
            'This inspection is not ready to authorise yet.',
        detail: 'inspection=$inspectionId progress=${current.progressLabel}',
        code: 'qc_incomplete',
      );
    }

    final row = await guard(
      () => _client
          .from('qc_inspections')
          .update(<String, dynamic>{
            'status': QcStatus.approved.wire,
            'inspector_id': _actor,
            'authorized_at': _now(),
          })
          .eq('id', inspectionId)
          .select('id')
          .single(),
    );
    return qcInspection(row['id'] as String);
  }

  /// D-006 — the fail path the mockup designed in CSS and made unreachable in JavaScript.
  ///
  /// `qc_fail_needs_reason` is the CHECK behind it; as with a CAD rejection, failing owes the
  /// bench a defect reason. The constraint name is translated into a sentence for the same
  /// reason it is for [submitCadReview].
  Future<QcInspection> failQc({
    required String inspectionId,
    required String defectReason,
  }) async {
    await _translateConstraint(
      () => _client
          .from('qc_inspections')
          .update(<String, dynamic>{
            'status': QcStatus.failed.wire,
            'inspector_id': _actor,
            'defect_reason': defectReason.trim(),
          })
          .eq('id', inspectionId)
          .select('id')
          .single(),
      constraint: 'qc_fail_needs_reason',
      message: 'Record the defect before failing the piece. The bench cannot rework a fault '
          'nobody described.',
    );
    return qcInspection(inspectionId);
  }

  // -------------------------------------------------------------- certification

  Future<List<Certificate>> certificates(String jobId) async {
    final rows = await guard(
      () => _client
          .from('certificates')
          .select()
          .eq('job_id', jobId)
          .order('created_at', ascending: false),
    );
    return [for (final row in rows) Certificate.fromJson(row)];
  }

  Future<Certificate?> certificate(String jobId) async {
    final row = await guard(
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

  /// Declare the lab leg. [isRequired] false is the cross-screen dependency the mockups stated
  /// and never wired: `fn_complete_stage` reads it to skip the `cert` stage, and the delivery
  /// schedule's certification buffer must be zeroed to match
  /// ([DeliverySchedule.certBufferAgreesWith]).
  Future<Certificate> saveCertificate({
    required String jobId,
    String? certificateId,
    bool isRequired = true,
    CertLab lab = CertLab.igi,
    String? labPartnerId,
    DateTime? expectedBack,
  }) async {
    final values = <String, dynamic>{
      'job_id': jobId,
      'required': isRequired,
      'lab': lab.wire,
      'lab_partner_id': labPartnerId,
      'expected_back': expectedBack == null ? null : _wireDate.format(expectedBack),
    };

    final row = certificateId == null
        ? await guard(
            () => _client.from('certificates').insert(values).select().single(),
          )
        : await guard(
            () => _client
                .from('certificates')
                .update(values)
                .eq('id', certificateId)
                .select()
                .single(),
          );
    return Certificate.fromJson(row);
  }

  /// Out the door to the lab. `expected_back` is the SLA the mockup had no field for, so
  /// nothing there could ever be chased.
  Future<Certificate> sendToLab({
    required String certificateId,
    DateTime? sentAt,
    DateTime? expectedBack,
  }) async {
    final row = await guard(
      () => _client
          .from('certificates')
          .update(<String, dynamic>{
            'status': CertStatus.sent.wire,
            'sent_at': _wireDate.format(sentAt ?? DateTime.now()),
            if (expectedBack != null) 'expected_back': _wireDate.format(expectedBack),
          })
          .eq('id', certificateId)
          .select()
          .single(),
    );
    return Certificate.fromJson(row);
  }

  Future<Certificate> setCertificateStatus({
    required String certificateId,
    required CertStatus status,
  }) async {
    final row = await guard(
      () => _client
          .from('certificates')
          .update(<String, dynamic>{'status': status.wire})
          .eq('id', certificateId)
          .select()
          .single(),
    );
    return Certificate.fromJson(row);
  }

  /// The certificate is only in hand when both the number and the PDF are
  /// ([Certificate.isComplete]), so both are written together.
  Future<Certificate> recordCertificate({
    required String certificateId,
    required String certNumber,
    required String jobId,
    FileUpload? pdf,
    String? pdfAttachmentId,
  }) async {
    final number = certNumber.trim();
    if (number.isEmpty) {
      throw const RuleViolation(
        message: 'Enter the certificate number from the report — ten digits, e.g. 1234567890.',
        code: 'cert_number_empty',
      );
    }

    var attachmentId = pdfAttachmentId;
    if (pdf != null) {
      final uploaded = await _upload(
        pdf,
        jobId: jobId,
        kind: AttachmentKind.certificatePdf,
      );
      attachmentId = uploaded.id;
    }

    final row = await guard(
      () => _client
          .from('certificates')
          .update(<String, dynamic>{
            'status': CertStatus.certified.wire,
            'cert_number': number,
            if (attachmentId != null) 'pdf_id': attachmentId,
            'rejection_note': null,
          })
          .eq('id', certificateId)
          .select()
          .single(),
    );
    return Certificate.fromJson(row);
  }

  /// D-006 — no lab-rejection path existed in the mockups. A lab that refuses the piece owes
  /// the shop a reason, the same asymmetry every other rejection in the system carries.
  Future<Certificate> rejectCertificate({
    required String certificateId,
    required String note,
  }) async {
    final text = note.trim();
    if (text.isEmpty) {
      throw const RuleViolation(
        message: 'Record what the lab objected to. Without it the bench cannot correct the '
            'piece before resubmitting.',
        code: 'cert_rejection_empty',
      );
    }
    final row = await guard(
      () => _client
          .from('certificates')
          .update(<String, dynamic>{
            'status': CertStatus.rejected.wire,
            'rejection_note': text,
          })
          .eq('id', certificateId)
          .select()
          .single(),
    );
    return Certificate.fromJson(row);
  }

  // -------------------------------------------------------------- shipping

  /// Every leg of the job, in rail order. The mockups proved a job needs several — inbound wax
  /// from "Central Hub", to-lab, from-lab, then final dispatch — not one shipment.
  Future<List<Shipment>> shipments(String jobId) async {
    final rows = await guard(
      () => _client
          .from('shipments')
          .select(_shipmentSelect)
          .eq('job_id', jobId)
          .order('created_at', ascending: true)
          .order('position', ascending: true, referencedTable: 'shipment_checks'),
    );
    return [for (final row in rows) Shipment.fromJson(row)];
  }

  Future<Shipment> shipment(String shipmentId) async {
    final row = await guard(
      () => _client
          .from('shipments')
          .select(_shipmentSelect)
          .eq('id', shipmentId)
          .order('position', ascending: true, referencedTable: 'shipment_checks')
          .single(),
    );
    return Shipment.fromJson(row);
  }

  /// Open a leg and seed its security protocol.
  ///
  /// `white_glove` is forced on for a direct-to-customer routing: "Requires white-glove
  /// unboxing prep." was stated in the mockup and never carried into the record, which is
  /// exactly the kind of instruction that gets lost between a screen and a packing bench.
  ///
  /// The protocol is seeded at creation rather than at dispatch time because
  /// `fn_dispatch_shipment` refuses a leg with an outstanding check — and a leg with *no*
  /// checks would otherwise dispatch unguarded.
  Future<Shipment> createShipment({
    required String jobId,
    required ShipmentLeg leg,
    DispatchRouting? routing,
    Courier? courier,
    String? courierOther,
    String? waybill,
    String? fromPartner,
    String? toPartner,
    Map<String, dynamic> toAddress = const <String, dynamic>{},
    Money? declaredValue,
    bool insured = true,
    bool isInternational = false,
    String? customsRef,
    bool signatureReq = true,
    bool whiteGlove = false,
    List<SecurityCheckSeed> securityChecks = defaultSecurityProtocol,
  }) async {
    final row = await guard(
      () => _client
          .from('shipments')
          .insert(<String, dynamic>{
            'job_id': jobId,
            'leg': leg.wire,
            'status': ShipmentStatus.draft.wire,
            'routing': routing?.wire,
            'courier': courier?.wire,
            'courier_other': courierOther?.trim(),
            // Quoted over the phone, so it is stored the way it is read out.
            'waybill': waybill?.trim().toUpperCase(),
            'from_partner': fromPartner,
            'to_partner': toPartner,
            'to_address': toAddress,
            if (declaredValue != null) 'declared_value': declaredValue.minor,
            if (declaredValue != null) 'currency': declaredValue.currency,
            'insured': insured,
            'is_international': isInternational || (courier?.isInternational ?? false),
            'customs_ref': customsRef?.trim(),
            'signature_req': signatureReq,
            'white_glove': whiteGlove || (routing?.needsWhiteGlove ?? false),
          })
          .select('id')
          .single(),
    );
    final shipmentId = row['id'] as String;

    if (securityChecks.isNotEmpty) {
      await guard(
        () => _client.from('shipment_checks').insert(<Map<String, dynamic>>[
          for (var i = 0; i < securityChecks.length; i++)
            <String, dynamic>{
              'shipment_id': shipmentId,
              'position': i + 1,
              'label': securityChecks[i].label,
              'reference': securityChecks[i].reference,
            },
        ]),
      );
    }

    return shipment(shipmentId);
  }

  /// Courier, waybill and declared value, editable until the leg is dispatched. Omitted
  /// arguments are left untouched; passing an empty waybill clears it.
  Future<Shipment> updateShipment({
    required String shipmentId,
    Courier? courier,
    String? courierOther,
    String? waybill,
    Money? declaredValue,
    bool? insured,
    bool? isInternational,
    String? customsRef,
    String? commercialInvoiceId,
    bool? signatureReq,
    bool? whiteGlove,
    Map<String, dynamic>? toAddress,
  }) async {
    final values = <String, dynamic>{
      if (courier != null) 'courier': courier.wire,
      if (courierOther != null) 'courier_other': _blankToNull(courierOther),
      if (waybill != null) 'waybill': _blankToNull(waybill.toUpperCase()),
      if (declaredValue != null) 'declared_value': declaredValue.minor,
      if (declaredValue != null) 'currency': declaredValue.currency,
      if (insured != null) 'insured': insured,
      if (isInternational != null) 'is_international': isInternational,
      if (customsRef != null) 'customs_ref': _blankToNull(customsRef),
      if (commercialInvoiceId != null) 'commercial_inv': commercialInvoiceId,
      if (signatureReq != null) 'signature_req': signatureReq,
      if (whiteGlove != null) 'white_glove': whiteGlove,
      if (toAddress != null) 'to_address': toAddress,
    };
    if (values.isEmpty) return shipment(shipmentId);

    await guard(
      () => _client.from('shipments').update(values).eq('id', shipmentId),
    );
    return shipment(shipmentId);
  }

  /// Tick one step of the protocol. A seal step with no serial recorded cannot be verified
  /// later ([ShipmentCheck.needsReference]), so the reference is written with the tick.
  ///
  /// [reference] omitted leaves the stored serial alone; passing an empty string clears it.
  /// Unticking must not wipe a seal number that was already applied to a box.
  ///
  /// Returns the whole leg so the dispatch button re-reads [Shipment.canDispatch] off the same
  /// response.
  Future<Shipment> setShipmentCheck({
    required String shipmentId,
    required String checkId,
    required bool passed,
    String? reference,
  }) async {
    await guard(
      () => _client
          .from('shipment_checks')
          .update(<String, dynamic>{
            'passed': passed,
            if (reference != null) 'reference': _blankToNull(reference),
            'checked_by': passed ? _actor : null,
            'checked_at': passed ? _now() : null,
          })
          .eq('id', checkId)
          .eq('shipment_id', shipmentId),
    );
    return shipment(shipmentId);
  }

  /// Add a step the standard protocol does not cover — a customs seal, a second count for a
  /// melee-heavy piece.
  Future<Shipment> addShipmentCheck({
    required String shipmentId,
    required String label,
    String? reference,
  }) async {
    final existing = await shipment(shipmentId);
    final nextPosition = existing.checks.isEmpty
        ? 1
        : existing.orderedChecks.last.position + 1;
    await guard(
      () => _client.from('shipment_checks').insert(<String, dynamic>{
        'shipment_id': shipmentId,
        'position': nextPosition,
        'label': label.trim(),
        'reference': reference == null ? null : _blankToNull(reference),
      }),
    );
    return shipment(shipmentId);
  }

  /// The real dispatch gate, decided in `fn_dispatch_shipment`.
  ///
  /// The mockup's version was cosmetic: its JavaScript toggled opacity classes and never set
  /// `.disabled`, so "Confirm Dispatch" fired with the tamper-seal protocol incomplete. The RPC
  /// counts the outstanding checks and refuses with its own wording — "Complete the security
  /// protocol first — 2 check(s) outstanding" — which `errors.dart` turns into a [RuleViolation]
  /// and which reaches the operator unaltered. Nothing is pre-checked here: the button is held
  /// shut by [Shipment.canDispatch], and the data is held shut by Postgres.
  Future<Shipment> dispatchShipment(String shipmentId) async {
    await guard<dynamic>(
      () => _client.rpc<dynamic>(
        'fn_dispatch_shipment',
        params: <String, dynamic>{'p_shipment': shipmentId, 'p_user': _actor},
      ),
    );
    return shipment(shipmentId);
  }

  Future<Shipment> markInTransit(String shipmentId) async {
    await guard(
      () => _client
          .from('shipments')
          .update(<String, dynamic>{'status': ShipmentStatus.inTransit.wire})
          .eq('id', shipmentId),
    );
    return shipment(shipmentId);
  }

  /// Delivered, with the signature that makes it a handover rather than a claim
  /// ([Shipment.needsProofOfDelivery]).
  Future<Shipment> markDelivered({
    required String shipmentId,
    required String jobId,
    DateTime? deliveredAt,
    String? receivedBy,
    FileUpload? proofOfDelivery,
    String? proofAttachmentId,
  }) async {
    var podId = proofAttachmentId;
    if (proofOfDelivery != null) {
      final uploaded = await _upload(
        proofOfDelivery,
        jobId: jobId,
        kind: AttachmentKind.proofOfDelivery,
      );
      podId = uploaded.id;
    }

    await guard(
      () => _client
          .from('shipments')
          .update(<String, dynamic>{
            'status': ShipmentStatus.delivered.wire,
            'delivered_at': _ts(deliveredAt ?? DateTime.now()),
            'received_by': receivedBy == null ? null : _blankToNull(receivedBy),
            if (podId != null) 'pod_id': podId,
          })
          .eq('id', shipmentId),
    );
    return shipment(shipmentId);
  }

  /// An international leg needs a customs reference *and* a commercial invoice
  /// ([Shipment.needsCustomsPaperwork]); the mockup's courier list offered Malca-Amit and had a
  /// field for neither.
  Future<Shipment> attachCommercialInvoice({
    required String shipmentId,
    required String jobId,
    required FileUpload invoice,
  }) async {
    final uploaded = await _upload(invoice, jobId: jobId, kind: AttachmentKind.invoice);
    await guard(
      () => _client
          .from('shipments')
          .update(<String, dynamic>{'commercial_inv': uploaded.id})
          .eq('id', shipmentId),
    );
    return shipment(shipmentId);
  }

  // -------------------------------------------------------------- plumbing

  /// One place that puts a file away, so bucket routing stays a property of the kind
  /// (`storage.dart`) and never a decision a caller can get wrong.
  Future<Attachment> _upload(
    FileUpload upload, {
    required String jobId,
    required AttachmentKind kind,
  }) =>
      _files.upload(upload._toRequest(orgId: _org, kind: kind, jobId: jobId));

  /// Turn a named CHECK constraint into the sentence the rule deserves.
  ///
  /// Postgres reports a CHECK violation as `new row for relation "cad_reviews" violates check
  /// constraint "cad_reject_needs_comment"`. `errors.dart` correctly classifies that as a
  /// [RuleViolation] — the rule *did* fire — but the wording is the constraint's, not the
  /// operator's. The rule stays in the database; only its wording is replaced, and the original
  /// text is kept in [DhFailure.detail] so a diagnostics sheet can still show what fired.
  Future<T> _translateConstraint<T>(
    Future<T> Function() body, {
    required String constraint,
    required String message,
  }) async {
    try {
      return await guard(body);
    } on RuleViolation catch (failure, stack) {
      final mentions = failure.message.contains(constraint) ||
          (failure.detail?.contains(constraint) ?? false);
      if (!mentions) rethrow;
      Error.throwWithStackTrace(
        RuleViolation(message: message, detail: failure.message, code: failure.code),
        stack,
      );
    }
  }

  /// Convention 7: Postgres holds instants in UTC. The client clock is used only for columns
  /// with no server default — every insert timestamp comes from `now()` in the database.
  String _now() => DateTime.now().toUtc().toIso8601String();

  String _ts(DateTime value) => value.toUtc().toIso8601String();

  String? _tsOrNull(DateTime? value) => value == null ? null : _ts(value);

  /// An empty text field means "cleared", not "empty string" — a waybill of `''` would print as
  /// a blank chip instead of an absent one.
  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

// ---------------------------------------------------------------- providers

@Riverpod(keepAlive: true)
ProductionRepository productionRepository(Ref ref) => ProductionRepository(
      ref.watch(supabaseProvider),
      ref.watch(repoIdentityProvider),
      ref.watch(attachmentStoreProvider),
    );

@riverpod
Future<List<CadRevision>> cadRevisions(Ref ref, String jobId) =>
    ref.watch(productionRepositoryProvider).cadRevisions(jobId);

@riverpod
Future<CadRevision?> currentCadRevision(Ref ref, String jobId) =>
    ref.watch(productionRepositoryProvider).currentCadRevision(jobId);

@riverpod
Future<List<CadAnnotation>> cadAnnotations(Ref ref, String revisionId) =>
    ref.watch(productionRepositoryProvider).cadAnnotations(revisionId);

/// D-011 rule 1 reads off this: `params?.canComplete` is what the caster's completion button
/// binds to.
@riverpod
Future<CastingParams?> castingParams(Ref ref, String jobId) =>
    ref.watch(productionRepositoryProvider).castingParams(jobId);

@riverpod
Future<List<StageMeasurement>> stageMeasurements(Ref ref, String jobId) =>
    ref.watch(productionRepositoryProvider).measurements(jobId);

/// D-011 rule 3 reads off this: `inspection?.canAuthorize` holds the authorisation button.
@riverpod
Future<QcInspection?> latestQcInspection(Ref ref, String jobId) =>
    ref.watch(productionRepositoryProvider).latestQcInspection(jobId);

@riverpod
Future<Certificate?> jobCertificate(Ref ref, String jobId) =>
    ref.watch(productionRepositoryProvider).certificate(jobId);

@riverpod
Future<List<Shipment>> jobShipments(Ref ref, String jobId) =>
    ref.watch(productionRepositoryProvider).shipments(jobId);
