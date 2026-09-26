/// Every write the QC loop makes, in one place, with one busy flag.
///
/// Two rules shape this file.
///
/// **D-011 rule 3 — authorisation enables only at a full checklist.** The rule itself lives in
/// three places that cannot disagree: [QcInspection.canAuthorize] holds the button shut,
/// `ProductionRepository.authorizeQc` re-reads the checklist before it writes the signature, and
/// `fn_complete_stage` refuses the stage advance while any item is unticked. Nothing here
/// re-implements it — a rule implemented four times is a rule that will disagree with itself.
///
/// **D-006 — the fail path the mockup designed and made unreachable.** Its CSS carried a
/// `bg-error` class that its own JavaScript removed in an else branch nothing could reach, which
/// is proof a FAILED state was designed and then left with no button. Failing here is three
/// writes: the defect reason onto the inspection (`qc_fail_needs_reason` requires it), the job to
/// `rework`, and a note on the thread so the bench reads the defect without coming to find the
/// inspector. A reinspection is then a **new attempt**, never an overwrite — the failed attempt
/// is the record of what went wrong.
///
/// Both consequential acts are two writes with a gap in the middle, and both report that gap
/// honestly rather than as a bare failure: an operator told "could not authorise" would press an
/// authorisation that already exists.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/repositories/thread_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/qc/qc_gateway.dart';

part 'qc_actions.g.dart';

/// Which QC write is in flight, so the screen spins the control that was actually pressed rather
/// than greying out everything it owns.
enum QcTask {
  open,
  check,
  evidence,
  authorize,
  fail,
  reinspect,
  measure,
}

/// Kept alive for the same reason `CadActions` is: an upload or an authorisation must survive the
/// inspector flicking to another screen while the round trip is open. An auto-disposed notifier
/// would be torn down under its own `finally`.
@Riverpod(keepAlive: true)
class QcActions extends _$QcActions {
  /// Null when nothing is in flight.
  @override
  QcTask? build() => null;

  bool get isBusy => state != null;

  bool isRunning(QcTask task) => state == task;

  ProductionRepository get _production => ref.read(productionRepositoryProvider);

  // -------------------------------------------------------------- opening the inspection

  /// Generate the checklist from what was agreed at intake, and open attempt 1.
  ///
  /// The list is never a fixed five. `quality_control` shipped exactly that, with no relationship
  /// to the job's own `acceptance_criteria`, which meant a piece with no certification still had
  /// "Certificate received" on its inspection and a piece with strict tolerance had nothing
  /// saying so.
  Future<QcInspection> openInspection(QcBundle bundle) async {
    _assertCanOpen(bundle);
    state = QcTask.open;
    try {
      final inspection = await _open(bundle);
      await _note(
        jobId: bundle.job.id,
        isInternal: true,
        body: 'QC inspection opened — attempt ${inspection.attempt}, '
            '${inspection.items.length} checks generated from the agreed acceptance criteria.',
      );
      return inspection;
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  /// A reinspection after rework.
  ///
  /// D-006: this is a new `qc_inspections` row with the next attempt number, so the failure and
  /// its defect reason stay on the record. `fn_complete_stage` counts unticked items across every
  /// inspection whose status is not `failed`, which is what lets a fresh attempt be authorised
  /// while the failed one remains.
  Future<QcInspection> reinspect(QcBundle bundle) async {
    final failed = bundle.current;
    if (failed == null || !failed.isFailed) {
      throw const RuleViolation(
        message: 'There is no failed inspection to redo. Open an inspection instead.',
        code: 'qc_nothing_to_reinspect',
      );
    }
    _assertCanOpen(bundle);

    state = QcTask.reinspect;
    try {
      // The piece is back from the bench, so the job comes off `rework` — otherwise it stays out
      // of the dashboard's In QC counter while an inspector is standing in front of it.
      await ref.read(qcGatewayProvider).reopenForInspection(
            bundle.job.id,
            attempt: bundle.nextAttempt,
          );
      final inspection = await _open(bundle);
      await _note(
        jobId: bundle.job.id,
        isInternal: true,
        body: 'Reinspection opened as attempt ${inspection.attempt}. '
            'Attempt ${failed.attempt} failed: ${failed.defectReason ?? 'no reason recorded'}.',
      );
      return inspection;
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  void _assertCanOpen(QcBundle bundle) {
    final blocked = bundle.openBlockedReason;
    if (blocked != null) {
      throw RuleViolation(message: blocked, code: 'qc_cannot_open');
    }
  }

  /// The repository call both entry points share. Does not touch [state] — its callers own that.
  Future<QcInspection> _open(QcBundle bundle) => _production.openQcInspection(
        jobId: bundle.job.id,
        checklist: bundle.seed,
        // The authority agreed at intake, not a default. Choosing `customer` inserts a portal
        // approval gate before sign-off, which the screen states out loud.
        authority: bundle.acceptance?.authority ?? QualityAuthority.internalQc,
        // "Matches approved CAD" is meaningless without naming which CAD.
        cadRevisionId: bundle.cad?.id,
      );

  // -------------------------------------------------------------- working the checklist

  /// Answer one line, or clear it back to unanswered.
  ///
  /// Three states, not two: [passed] null is what an inspector needs when they tick the wrong
  /// row, and it is a different fact from a recorded failure.
  Future<void> setCheck({
    required QcBundle bundle,
    required QcChecklistItem item,
    required bool? passed,
  }) async {
    final inspection = _requireOpenInspection(bundle);
    state = QcTask.check;
    try {
      await _production.setQcCheck(
        inspectionId: inspection.id,
        itemId: item.id,
        passed: passed,
      );
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  /// The file input the mockup's "inspection evidence" dropzone never had.
  ///
  /// Routed to the `vault` bucket by [AttachmentKind.qcEvidence] — evidence behind an
  /// irreversible authorisation is not customer-facing.
  Future<void> attachEvidence({
    required QcBundle bundle,
    required QcChecklistItem item,
    required File file,
    required String filename,
  }) async {
    final inspection = _requireOpenInspection(bundle);
    state = QcTask.evidence;
    try {
      await _production.attachQcEvidence(
        inspectionId: inspection.id,
        itemId: item.id,
        jobId: bundle.job.id,
        evidence: FileUpload.file(
          file,
          filename: filename,
          caption: '${item.label} — ${bundle.job.displayCode}',
        ),
      );
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  // -------------------------------------------------------------- the decision

  /// D-011 rule 3 — sign the piece off and move the job on.
  ///
  /// Two writes. `authorizeQc` records the signature and re-reads the checklist first, because
  /// the inspection may have been open on this device for twenty minutes while someone else
  /// reopened a line. `fn_complete_stage` then closes the QC stage, and only when the job is
  /// actually standing at QC ([QcBundle.stageToClose]) — a signature must not walk a job that is
  /// still at polishing.
  Future<void> authorize(QcBundle bundle) async {
    final inspection = _requireOpenInspection(bundle);
    state = QcTask.authorize;
    try {
      await _production.authorizeQc(inspection.id);

      final closing = bundle.stageToClose;
      if (closing != null) {
        try {
          await ref.read(jobRepositoryProvider).completeStage(
                jobId: bundle.job.id,
                stage: closing.stage,
                notes: 'QC attempt ${inspection.attempt} authorised — '
                    '${inspection.progressLabel} checks passed.',
              );
        } on DhFailure catch (failure, stack) {
          // The signature is written. Reporting a bare "could not authorise" here would send the
          // inspector back to sign a piece that is already signed.
          Error.throwWithStackTrace(
            RuleViolation(
              message: 'The inspection is authorised and on the record, but the job did not move '
                  'on: ${failure.message}',
              detail: failure.detail,
              code: failure.code,
            ),
            stack,
          );
        }
      }

      await _note(
        jobId: bundle.job.id,
        // A piece passing QC is progress the customer is entitled to see.
        isInternal: false,
        body: 'Quality control passed. ${inspection.items.length} checks verified'
            '${bundle.cad == null ? '' : ' against CAD ${bundle.cad!.version}'}.',
      );
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  /// D-006 — fail the piece and send it back.
  ///
  /// [defectReason] is required by `qc_fail_needs_reason` in Postgres and by the prompt in the
  /// UI, the same asymmetry a CAD rejection carries: the bench cannot rework a fault nobody
  /// described. The job then goes to `rework`, which is what takes it out of the In QC counter
  /// while the bench has it back.
  Future<void> fail({
    required QcBundle bundle,
    required String defectReason,
  }) async {
    final inspection = _requireOpenInspection(bundle);
    final reason = defectReason.trim();
    state = QcTask.fail;
    try {
      await _production.failQc(inspectionId: inspection.id, defectReason: reason);

      try {
        await ref.read(jobRepositoryProvider).markForRework(bundle.job.id, reason: reason);
      } on DhFailure catch (failure, stack) {
        // The failure is recorded either way. Saying so stops an inspector failing the piece
        // twice trying to make the status move.
        Error.throwWithStackTrace(
          RuleViolation(
            message: 'Attempt ${inspection.attempt} is recorded as failed, but the job status did '
                'not change to rework: ${failure.message}',
            detail: failure.detail,
            code: failure.code,
          ),
          stack,
        );
      }

      await _note(
        jobId: bundle.job.id,
        // The defect is shop talk aimed at the bench, not a customer update.
        isInternal: true,
        body: 'QC failed at attempt ${inspection.attempt}.\n\n$reason',
      );
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  // -------------------------------------------------------------- measurement

  /// What the bench actually weighed.
  ///
  /// No screen in the 46 mockups captured a production measurement. `order_details` showed the
  /// binding spec — "Target Weight 4.2g ±0.1g", the only spec in the corpus rendered in gold —
  /// as read-only, while a note in the same thread said "Update spec sheet".
  ///
  /// [targetG] and [toleranceG] are copied from the spec at the moment of measurement so a later
  /// spec edit cannot retroactively turn a passed measurement into a failed one. `within_tol` is
  /// a generated column and is never written.
  Future<StageMeasurement> recordMeasurement({
    required String jobId,
    required LifecycleStage stage,
    required double weightG,
    double? targetG,
    double? toleranceG,
    double? scrapG,
    String? notes,
    File? photo,
    String? photoFilename,
  }) async {
    state = QcTask.measure;
    try {
      String? photoId;
      if (photo != null) {
        final orgId = ref.read(repoIdentityProvider).requireOrgId();
        final uploaded = await ref.read(attachmentStoreProvider).upload(
              UploadRequest.file(
                orgId: orgId,
                // A scale reading is internal evidence, so it goes to the vault like every other
                // QC artefact rather than into the customer-visible bucket.
                kind: AttachmentKind.qcEvidence,
                file: photo,
                filename: photoFilename ?? 'scale_reading.jpg',
                jobId: jobId,
                caption: 'Scale reading — ${stage.label}',
              ),
            );
        photoId = uploaded.id;
      }

      final measurement = await _production.recordMeasurement(
        jobId: jobId,
        stage: stage,
        weightG: weightG,
        targetG: targetG,
        toleranceG: toleranceG,
        scrapG: scrapG,
        notes: notes,
        photoId: photoId,
      );

      await _note(
        jobId: jobId,
        isInternal: true,
        body: _measurementNote(stage, measurement),
      );
      return measurement;
    } finally {
      state = null;
      _refresh(jobId);
    }
  }

  static String _measurementNote(LifecycleStage stage, StageMeasurement measurement) {
    final lines = <String>[
      '${stage.label} measurement: ${measurement.measurementLabel}.',
      if (measurement.targetG != null)
        measurement.isWithinTolerance
            ? 'Within tolerance (${measurement.varianceLabel}).'
            : 'OUT OF TOLERANCE by ${measurement.varianceLabel}.',
      if ((measurement.scrapG ?? 0.0) > 0) 'Loss recorded: ${gramLabel(measurement.scrapG)}.',
    ];
    final notes = measurement.notes?.trim();
    if (notes != null && notes.isNotEmpty) lines.add(notes);
    return lines.join(' ');
  }

  // -------------------------------------------------------------- plumbing

  QcInspection _requireOpenInspection(QcBundle bundle) {
    final inspection = bundle.current;
    if (inspection == null) {
      throw const RuleViolation(
        message: 'No inspection is open on this job. Generate the checklist first.',
        code: 'qc_no_inspection',
      );
    }
    return inspection;
  }

  /// Invalidated even on failure: `authorizeQc` and `failQc` each write before the second step
  /// can fail, so the screen must re-read rather than keep showing an open decision.
  ///
  /// `qc_inspections` and `stage_measurements` are not on the job realtime channel, so nothing
  /// brings them back on their own.
  void _refresh(String jobId) {
    ref
      ..invalidate(qcBundleProvider(jobId))
      ..invalidate(measurementContextProvider(jobId))
      ..invalidate(latestQcInspectionProvider(jobId))
      ..invalidate(stageMeasurementsProvider(jobId))
      ..invalidate(jobSnapshotProvider(jobId));
  }

  /// A thread post that accompanies a decision, best effort.
  ///
  /// The decision itself is already in `qc_inspections` and `activity_events`. A thread post that
  /// did not land must not turn a completed, irreversible authorisation into a reported failure.
  Future<void> _note({
    required String jobId,
    required String body,
    required bool isInternal,
  }) async {
    try {
      await ref.read(threadRepositoryProvider).postMessage(
            jobId: jobId,
            body: body,
            stage: LifecycleStage.qc,
            isInternal: isInternal,
          );
    } on DhFailure catch (_) {
      // Intentionally ignored — see the doc comment.
    }
  }
}
