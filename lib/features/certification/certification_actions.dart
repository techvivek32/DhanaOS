/// Every write the certification leg makes, in one place, with one busy flag.
///
/// The load-bearing one is [CertActions.setRequired], because "Certification Required: No" is the
/// cross-screen dependency the mockups declared and never wired. Answering No is **three** writes,
/// not one, and missing any of them leaves the job lying:
///
///  1. `certificates.required = false` — what `fn_complete_stage` reads to mark the `cert` stage
///     skipped when the job reaches it.
///  2. `acceptance_criteria.cert_lab = none` — the agreement, which is where the delivery
///     schedule takes its cue. Writing it through `SpecRepository.upsertAcceptance` is what zeroes
///     `delivery_schedules.cert_buffer_d`, so the promised date stops reserving three days for a
///     lab that will never see the piece.
///  3. If the job is *already standing* at certification, the stage has to be closed here —
///     `fn_complete_stage` only skips `cert` on the way *into* it, and a job parked on a stage
///     nobody will ever work is how a board grows a dead column.
///
/// Every status move also writes an `activity_events` row (D-005). `certificates` is a mutable row
/// because a lab's own status changes; the history of the leg exists only because each transition
/// is logged as it happens, into a table with UPDATE and DELETE revoked.
library;

import 'dart:io';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/repositories/spec_repository.dart';
import 'package:dhanaos/data/repositories/thread_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/certification/certification_gateway.dart';

part 'certification_actions.g.dart';

/// Which certification write is in flight, so the screen spins the control that was pressed.
enum CertTask {
  declare,
  send,
  advance,
  record,
  reject,
  resubmit,
  close,
}

@Riverpod(keepAlive: true)
class CertActions extends _$CertActions {
  /// Null when nothing is in flight.
  @override
  CertTask? build() => null;

  bool get isBusy => state != null;

  bool isRunning(CertTask task) => state == task;

  ProductionRepository get _production => ref.read(productionRepositoryProvider);

  SpecRepository get _specs => ref.read(specRepositoryProvider);

  JobRepository get _jobs => ref.read(jobRepositoryProvider);

  CertGateway get _gateway => ref.read(certGatewayProvider);

  // -------------------------------------------------------------- the conditional

  /// Declare, or un-declare, the lab leg.
  ///
  /// See the library comment: No is three writes. Yes is two — the certificate row and the
  /// agreement, which restores the delivery buffer if it had been zeroed.
  Future<void> setRequired({
    required CertBundle bundle,
    required bool isRequired,
    CertLab lab = CertLab.igi,
    String? labPartnerId,
    DateTime? expectedBack,
  }) async {
    final jobId = bundle.job.id;
    // `CertLab.none` and `required = false` are the same decision written twice, once in each
    // table that acts on it. Keeping them in step is the whole point of this method.
    final effectiveLab = isRequired ? lab : CertLab.none;

    state = CertTask.declare;
    try {
      await _production.saveCertificate(
        jobId: jobId,
        certificateId: bundle.certificate?.id,
        isRequired: isRequired,
        lab: effectiveLab,
        labPartnerId: isRequired ? labPartnerId : null,
        expectedBack: isRequired ? expectedBack : null,
      );

      // `upsertAcceptance` carries the buffer sync: `none` zeroes `cert_buffer_d`, and a real lab
      // restores the three-day default only when it is currently zero — an operator who
      // deliberately set five days keeps them.
      await _specs.upsertAcceptance(jobId, certLab: Opt(effectiveLab));

      await _gateway.logTransition(
        jobId: jobId,
        status: isRequired ? CertStatus.waiting : null,
        summary: isRequired
            ? 'Certification declared: ${effectiveLab.label}'
            : 'Certification not required',
        detail: isRequired
            ? expectedBack == null
                ? 'No expected return date set.'
                : 'Expected back ${_day(expectedBack)}.'
            : 'The certification stage will be skipped and the delivery plan no longer reserves '
                'days for a lab.',
      );

      // `fn_complete_stage` skips `cert` on the way in, not once the job is standing on it.
      if (!isRequired && bundle.stageToClose != null) {
        await _closeStage(
          jobId: jobId,
          notes: 'No certification required — stage closed without a lab.',
        );
      }

      await _note(
        jobId: jobId,
        isInternal: false,
        body: isRequired
            ? 'Certification with ${effectiveLab.label} is on the job.'
            : 'This piece will ship without a gem-lab certificate, as agreed.',
      );
    } finally {
      state = null;
      _refresh(jobId);
    }
  }

  // -------------------------------------------------------------- out and back

  /// Out of the building. `expected_back` is the SLA the mockup had no field for, so nothing there
  /// could ever be chased.
  Future<void> sendToLab({
    required CertBundle bundle,
    required DateTime sentAt,
    required DateTime expectedBack,
  }) async {
    final cert = _requireLeg(bundle);
    state = CertTask.send;
    try {
      await _production.sendToLab(
        certificateId: cert.id,
        sentAt: sentAt,
        expectedBack: expectedBack,
      );
      await _gateway.logTransition(
        jobId: bundle.job.id,
        status: CertStatus.sent,
        summary: 'Sent to ${bundle.labLabel}',
        detail: 'Expected back ${_day(expectedBack)}.',
      );
      await _note(
        jobId: bundle.job.id,
        isInternal: false,
        body: 'The piece has gone to ${bundle.labLabel} for certification. Expected back '
            '${_day(expectedBack)}.',
      );
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  /// Re-promise a late lab.
  ///
  /// A lab that has missed its date gives a new one over the phone, and that conversation has to
  /// land somewhere or the next person chases the old date. `saveCertificate` writes only the
  /// declaration columns, so the leg's status is untouched — this moves the SLA, nothing else.
  Future<void> reviseSla({
    required CertBundle bundle,
    required DateTime expectedBack,
  }) async {
    final cert = _requireLeg(bundle);
    state = CertTask.declare;
    try {
      await _production.saveCertificate(
        jobId: bundle.job.id,
        certificateId: cert.id,
        isRequired: cert.isRequired,
        lab: cert.lab,
        labPartnerId: cert.labPartnerId,
        expectedBack: expectedBack,
      );
      await _gateway.logTransition(
        jobId: bundle.job.id,
        summary: '${bundle.labLabel} re-promised the certificate',
        detail: 'New expected return ${_day(expectedBack)}'
            '${cert.expectedBack == null ? '' : ', was ${_day(cert.expectedBack!)}'}.',
      );
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  /// Move the leg one step along — received, grading, back in the shop.
  ///
  /// Forward-only ([CertStep.nextStatuses]): these rows record what a third party did, and a
  /// screen that walked them backwards would be inventing lab history.
  Future<void> advance({
    required CertBundle bundle,
    required CertStatus status,
  }) async {
    final cert = _requireLeg(bundle);
    if (!bundle.nextStatuses.contains(status)) {
      throw RuleViolation(
        message: 'This leg is at ${bundle.status.label}. It cannot move straight to '
            '${status.label}.',
        detail: 'from=${bundle.status.wire} to=${status.wire}',
        code: 'cert_status_out_of_order',
      );
    }

    state = CertTask.advance;
    try {
      await _production.setCertificateStatus(certificateId: cert.id, status: status);
      await _gateway.logTransition(
        jobId: bundle.job.id,
        status: status,
        summary: switch (status) {
          CertStatus.atLab => '${bundle.labLabel} received the piece',
          CertStatus.inProgress => 'Grading in progress at ${bundle.labLabel}',
          CertStatus.returned => 'Piece and certificate back in the shop',
          _ => 'Certification status: ${status.label}',
        },
      );
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  /// The report is in hand: number and PDF together.
  ///
  /// [Certificate.isComplete] requires both, which is why `recordCertificate` writes them in one
  /// call — a number with no report behind it is a claim, and a report nobody indexed by number
  /// cannot be found again.
  Future<void> recordCertificate({
    required CertBundle bundle,
    required String certNumber,
    File? pdf,
    String? pdfFilename,
  }) async {
    final cert = _requireLeg(bundle);
    state = CertTask.record;
    try {
      final saved = await _production.recordCertificate(
        certificateId: cert.id,
        certNumber: certNumber,
        jobId: bundle.job.id,
        pdf: pdf == null
            ? null
            : FileUpload.file(
                pdf,
                filename: pdfFilename,
                caption: '${bundle.labLabel} certificate — ${bundle.job.displayCode}',
              ),
      );
      await _gateway.logTransition(
        jobId: bundle.job.id,
        status: CertStatus.certified,
        summary: '${bundle.labLabel} certificate ${saved.certNumber}',
        detail: saved.pdfId == null
            ? 'Number recorded. The report itself is still missing.'
            : 'Number and report both on file.',
      );
      await _note(
        jobId: bundle.job.id,
        isInternal: false,
        body: '${bundle.labLabel} has certified the piece. Certificate ${saved.certNumber}.',
      );
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  // -------------------------------------------------------------- rejection (D-006)

  /// The lab refused the piece.
  ///
  /// D-006: no rejection path existed anywhere in the mockups. A lab that refuses owes the shop a
  /// reason, the same asymmetry every other rejection in the system carries — and the cert stage
  /// goes `blocked` through a `job_exceptions` row, because an issue that does not show on the
  /// board is an issue nobody acts on.
  Future<void> reject({
    required CertBundle bundle,
    required String note,
  }) async {
    final cert = _requireLeg(bundle);
    final reason = note.trim();
    state = CertTask.reject;
    try {
      await _production.rejectCertificate(certificateId: cert.id, note: reason);
      await _gateway.logTransition(
        jobId: bundle.job.id,
        status: CertStatus.rejected,
        kind: ActivityKind.rejected,
        summary: '${bundle.labLabel} rejected the piece',
        detail: reason,
      );

      try {
        await _jobs.raiseException(
          jobId: bundle.job.id,
          stage: LifecycleStage.cert,
          title: '${bundle.labLabel} rejected the piece',
          detail: reason,
          severity: ActionSeverity.error,
          partnerId: cert.labPartnerId,
        );
      } on DhFailure catch (failure, stack) {
        // The rejection is recorded either way. Saying so stops an operator rejecting it twice
        // trying to make the board show it.
        Error.throwWithStackTrace(
          RuleViolation(
            message: 'The rejection is on the record, but the certification stage was not '
                'blocked: ${failure.message}',
            detail: failure.detail,
            code: failure.code,
          ),
          stack,
        );
      }

      await _note(
        jobId: bundle.job.id,
        // A lab rejection is shop business until the shop knows what it is doing about it.
        isInternal: true,
        body: '${bundle.labLabel} rejected the piece.\n\n$reason',
      );
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  /// Send it back after a rejection.
  ///
  /// A resubmission is a **new** `certificates` row, not an edit of the rejected one: the
  /// rejection and its reason are the record of what the lab objected to, and overwriting them
  /// would erase the only evidence that the first attempt happened.
  Future<void> resubmit({
    required CertBundle bundle,
    required DateTime sentAt,
    required DateTime expectedBack,
    required String fixNote,
  }) async {
    final rejected = _requireLeg(bundle);
    if (!rejected.isRejected) {
      throw const RuleViolation(
        message: 'This leg was not rejected, so there is nothing to resubmit.',
        code: 'cert_not_rejected',
      );
    }
    final fix = fixNote.trim();

    state = CertTask.resubmit;
    try {
      final fresh = await _production.saveCertificate(
        jobId: bundle.job.id,
        isRequired: true,
        lab: rejected.lab,
        labPartnerId: rejected.labPartnerId,
        expectedBack: expectedBack,
      );
      await _production.sendToLab(
        certificateId: fresh.id,
        sentAt: sentAt,
        expectedBack: expectedBack,
      );

      // The exception is what held the stage blocked; closing it is what releases the rail.
      final open = bundle.openException;
      if (open != null) {
        await _jobs.resolveException(exceptionId: open.id, resolution: fix);
      }

      await _gateway.logTransition(
        jobId: bundle.job.id,
        status: CertStatus.sent,
        summary: 'Resubmitted to ${bundle.labLabel}',
        detail: '$fix Expected back ${_day(expectedBack)}.',
      );
      await _note(
        jobId: bundle.job.id,
        isInternal: false,
        body: 'The piece has gone back to ${bundle.labLabel} after correction. Expected back '
            '${_day(expectedBack)}.',
      );
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  // -------------------------------------------------------------- closing the stage

  /// Close certification and move the job on.
  Future<void> closeStage(CertBundle bundle) async {
    final closing = bundle.stageToClose;
    if (closing == null) {
      throw const RuleViolation(
        message: 'The job is not standing at certification, so there is no stage to close here.',
        code: 'cert_stage_not_active',
      );
    }
    if (!bundle.canCloseStage) {
      throw RuleViolation(
        message: bundle.closeBlockedReason ?? 'Certification is not finished yet.',
        code: 'cert_incomplete',
      );
    }

    state = CertTask.close;
    try {
      await _closeStage(
        jobId: bundle.job.id,
        notes: bundle.isRequired
            ? '${bundle.labLabel} certificate ${bundle.certificate?.certNumber ?? ''} on file.'
                .trim()
            : 'No certification required.',
      );
      await _note(
        jobId: bundle.job.id,
        isInternal: false,
        body: bundle.isRequired
            ? 'Certification complete. The piece moves to ${bundle.nextStageLabel}.'
            : 'Certification skipped as agreed. The piece moves to ${bundle.nextStageLabel}.',
      );
    } finally {
      state = null;
      _refresh(bundle.job.id);
    }
  }

  /// The one place that advances the rail. A blocked stage refuses, which is correct: an open
  /// exception is exactly the thing that should stop a job walking on.
  Future<void> _closeStage({required String jobId, required String notes}) =>
      _jobs.completeStage(jobId: jobId, stage: LifecycleStage.cert, notes: notes);

  // -------------------------------------------------------------- plumbing

  Certificate _requireLeg(CertBundle bundle) {
    final cert = bundle.certificate;
    if (cert == null) {
      throw const RuleViolation(
        message: 'No certification leg has been declared on this job yet. Choose a lab first.',
        code: 'cert_no_leg',
      );
    }
    return cert;
  }

  /// '12 Feb 2026' — the date an operator reads back over the phone to a lab.
  static String _day(DateTime value) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = value.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }

  /// `certificates` is not on the job realtime channel, so nothing brings it back on its own.
  void _refresh(String jobId) {
    ref
      ..invalidate(certBundleProvider(jobId))
      ..invalidate(jobCertificateProvider(jobId))
      ..invalidate(deliveryScheduleProvider(jobId))
      ..invalidate(acceptanceCriteriaProvider(jobId))
      ..invalidate(jobSnapshotProvider(jobId));
  }

  /// A thread post that accompanies a transition, best effort. A post that did not land must not
  /// turn a completed write into a reported failure.
  Future<void> _note({
    required String jobId,
    required String body,
    required bool isInternal,
  }) async {
    try {
      await ref.read(threadRepositoryProvider).postMessage(
            jobId: jobId,
            body: body,
            stage: LifecycleStage.cert,
            isInternal: isInternal,
          );
    } on DhFailure catch (_) {
      // Intentionally ignored — see the doc comment.
    }
  }
}
