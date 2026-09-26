/// Every write the vendor surface makes, in one place, with one busy flag.
///
/// **D-011 rule 1 is the spine of this file.** `caster_dashboard` shipped "Mark Complete"
/// DISABLED behind a mandatory `accept="image/*"` upload, helper "Required before marking
/// complete" — the single best idea in the 46-screen corpus. It is implemented in three places
/// that cannot disagree: [PartnerJobBrief.canComplete] holds the button shut,
/// `casting_params.photo_id` is the fact, and `fn_complete_stage` raises
/// `check_violation` — "A casting photo is required before marking this stage complete" — if
/// anything ever reaches it without one. Nothing here re-implements the rule; a rule implemented
/// four times is a rule that will disagree with itself.
///
/// **A schema dependency you will meet in a live build.** `0009_rls.sql` gives every job-scoped
/// child table one policy shape:
///
/// ```sql
/// create policy casting_params_write on casting_params for all
///   using (auth_principal() = 'internal' and auth_can_see_job(job_id))
///   with check (auth_can_see_job(job_id));
/// ```
///
/// For an INSERT Postgres evaluates only `with check`, so a partner *can* create the row. For an
/// UPDATE it also evaluates `using`, which a partner fails — and both
/// `ProductionRepository.attachCastingPhoto` and `saveCastingParams` are upserts, so the moment
/// the workshop has already written the brief the caster's own evidence write is refused with
/// `42501`. The fix belongs in the migration (a `casting_params_partner_update` policy limited to
/// `photo_id, tree_weight_g, notes`, or an `fn_attach_casting_photo` with `security definer`); the
/// photo itself is already uploaded and on the job by then, so what this file owes the caster is
/// the truth about where it got to. [_translateCastingWrite] is that sentence.
///
/// **"Report Issue" was a 50/50 peer of the happy path with no screen behind it.** Raising one
/// here does three things: the `job_exceptions` row, the `job_stages` block that puts it on the
/// board, and an `action_items` row so it surfaces in the manufacturer's Action Queue as
/// "Caster delayed on DH-2026-01842". The third is best effort — an exception that is on the
/// record must not be reported as a failure because a notification did not land.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/data/repositories/dashboard_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/repositories/thread_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/partner/partner_gateway.dart';

part 'partner_actions.g.dart';

/// Which vendor write is in flight, so the screen spins the control that was actually pressed
/// rather than greying out everything it owns.
enum PartnerTask { photo, record, complete, issue }

/// Kept alive for the same reason `QcActions` is: a photo upload from a shop-floor tablet must
/// survive the caster flicking to another screen while the round trip is open. An auto-disposed
/// notifier would be torn down under its own `finally`.
@Riverpod(keepAlive: true)
class PartnerActions extends _$PartnerActions {
  /// Null when nothing is in flight.
  @override
  PartnerTask? build() => null;

  bool get isBusy => state != null;

  bool isRunning(PartnerTask task) => state == task;

  ProductionRepository get _production => ref.read(productionRepositoryProvider);

  JobRepository get _jobs => ref.read(jobRepositoryProvider);

  // -------------------------------------------------------------- D-011 rule 1

  /// Upload the casting photo. This is the write that unlocks completion and nothing else does.
  ///
  /// The order is fixed by `ProductionRepository.attachCastingPhoto`: the object goes into
  /// `job-files`, the `attachments` row is written, then `casting_params.photo_id` points at it.
  /// If the last step is refused the photo is still on the job — which is why the refusal is
  /// translated into a sentence that says exactly that, instead of reading as a lost upload.
  Future<CastingParams> attachPhoto({
    required PartnerJobBrief brief,
    required File file,
    required String filename,
  }) async {
    _assertCastingStage(brief);
    state = PartnerTask.photo;
    try {
      final params = await _production.attachCastingPhoto(
        jobId: brief.job.id,
        photo: FileUpload.file(
          file,
          filename: filename,
          // A caption is what makes evidence findable six weeks later.
          caption: 'Cast tree — ${brief.job.displayCode}',
        ),
      );
      await _note(
        jobId: brief.job.id,
        stage: brief.stage.stage,
        body: 'Casting photo uploaded. The stage can be closed now.',
      );
      return params;
    } on DhFailure catch (failure, stack) {
      Error.throwWithStackTrace(_translateCastingWrite(failure, uploaded: true), stack);
    } finally {
      state = null;
      _refresh(brief.job.id);
    }
  }

  /// Record what the caster actually poured: the tree weight and any note.
  ///
  /// `saveCastingParams` owns the whole row — it writes every column it takes, including back to
  /// null — so the workshop's own instruction (alloy, flask and metal temperatures, the dates) is
  /// echoed back unchanged. Those three are the workshop's numbers and the spec card renders them
  /// read-only; a vendor form that silently blanked them would destroy the brief the next shift
  /// works from.
  Future<CastingParams> recordPour({
    required PartnerJobBrief brief,
    double? treeWeightG,
    String? notes,
  }) async {
    _assertCastingStage(brief);
    final existing = brief.casting;
    state = PartnerTask.record;
    try {
      final params = await _production.saveCastingParams(
        jobId: brief.job.id,
        partnerId: existing?.partnerId ?? brief.stage.assignedPartner,
        alloy: existing?.alloy,
        flaskTempC: existing?.flaskTempC,
        metalTempC: existing?.metalTempC,
        receivedAt: existing?.receivedAt,
        expectedAt: existing?.expectedAt,
        treeWeightG: treeWeightG ?? existing?.treeWeightG,
        notes: notes ?? existing?.notes,
      );
      final lines = <String>[
        if (treeWeightG != null) 'Tree weight recorded: ${gramLabel(treeWeightG)}.',
        if (notes != null && notes.trim().isNotEmpty) notes.trim(),
      ];
      if (lines.isNotEmpty) {
        await _note(
          jobId: brief.job.id,
          stage: brief.stage.stage,
          body: lines.join(' '),
        );
      }
      return params;
    } on DhFailure catch (failure, stack) {
      Error.throwWithStackTrace(_translateCastingWrite(failure, uploaded: false), stack);
    } finally {
      state = null;
      _refresh(brief.job.id);
    }
  }

  // -------------------------------------------------------------- close the stage

  /// Hand the work back. D-005: this never writes `jobs.current_stage` — `fn_complete_stage`
  /// moves the rail and the trigger updates the cache and writes the audit row.
  ///
  /// The client-side gate is re-read from [PartnerJobBrief] first, because a button bound to a
  /// brief loaded twenty minutes ago can outlive the fact behind it. The database checks it again
  /// regardless; this only keeps the caster from pressing something that is guaranteed to refuse.
  Future<void> completeStage({
    required PartnerJobBrief brief,
    String? notes,
  }) async {
    final blocked = brief.completeBlockedReason;
    if (blocked != null) {
      throw RuleViolation(
        message: brief.needsCastingEvidence
            // The rule in the database's own words, so the sentence is the same whichever layer
            // refuses it.
            ? 'A casting photo is required before marking this stage complete'
            : blocked,
        detail: 'job=${brief.job.id} stage=${brief.stage.stage.wire}',
        code: 'casting_photo_required',
      );
    }

    state = PartnerTask.complete;
    try {
      await _jobs.completeStage(
        jobId: brief.job.id,
        stage: brief.stage.stage,
        notes: _completionNote(brief, notes),
      );
      await _note(
        jobId: brief.job.id,
        stage: brief.stage.stage,
        body: _completionNote(brief, notes),
      );
    } finally {
      state = null;
      _refresh(brief.job.id);
    }
  }

  /// What goes on the rail row and the thread. The tree weight belongs here: it is the first
  /// figure the bench checks the returned casting against.
  static String _completionNote(PartnerJobBrief brief, String? extra) {
    final parts = <String>[
      '${brief.stage.stage.label} completed'
          '${brief.partner == null ? '' : ' by ${brief.partner!.name}'}.',
      if (brief.casting?.treeWeightG != null)
        'Tree weight ${gramLabel(brief.casting!.treeWeightG)}.',
      if (brief.targetWeightLabel != '—') 'Target ${brief.targetWeightLabel}.',
    ];
    final note = extra?.trim();
    if (note != null && note.isNotEmpty) parts.add(note);
    return parts.join(' ');
  }

  // -------------------------------------------------------------- exceptions

  /// Report an issue — the exception path the mockups drew as a 50/50 peer of the happy path and
  /// never built.
  ///
  /// [blockStage] flips the rail row to `blocked`, which is what puts the issue on the
  /// manufacturer's board rather than leaving it in a vendor's inbox. It defaults on: an issue
  /// that does not show on the board is an issue nobody acts on. `state` and `blocked_reason` are
  /// inside the column grant a partner holds, so a caster really can block their own stage.
  Future<JobException> reportIssue({
    required PartnerJobBrief brief,
    required String title,
    String? detail,
    ActionSeverity severity = ActionSeverity.warning,
    bool blockStage = true,
  }) async {
    final headline = title.trim();
    state = PartnerTask.issue;
    try {
      final raised = await _jobs.raiseException(
        jobId: brief.job.id,
        stage: brief.stage.stage,
        title: headline,
        detail: detail,
        severity: severity,
        // Raised by a vendor, so resolving it needs a phone call rather than a shop-floor fix —
        // which is what `JobException.isExternal` reads off.
        partnerId: brief.stage.assignedPartner ?? brief.viewerPartnerId,
        blockStage: blockStage,
      );

      await _queueForWorkshop(brief: brief, exception: raised);
      await _note(
        jobId: brief.job.id,
        stage: brief.stage.stage,
        body: _issueNote(raised),
      );
      return raised;
    } finally {
      state = null;
      _refresh(brief.job.id);
    }
  }

  static String _issueNote(JobException raised) {
    final body = raised.detail?.trim();
    return body == null || body.isEmpty
        ? 'Issue reported: ${raised.title}'
        : 'Issue reported: ${raised.title}\n\n$body';
  }

  /// Put the issue in the manufacturer's Action Queue.
  ///
  /// "Caster delayed on DH-2026-01048 → Follow Up" was a hardcoded row with a decorative button
  /// in `manufacturer_dashboard`. This is the real one, and its `cta_route` is a live in-app path
  /// so the button goes somewhere.
  ///
  /// Best effort on purpose. The exception is already in `job_exceptions` and the stage is already
  /// blocked; a failed notification must not turn that into a reported failure and send the caster
  /// round again.
  Future<void> _queueForWorkshop({
    required PartnerJobBrief brief,
    required JobException exception,
  }) async {
    try {
      await ref.read(dashboardRepositoryProvider).raiseActionItem(
            // The mockup's phrasing, now derived: '<who> <what> on <code>'.
            label: brief.partner == null
                ? '${exception.title} on ${brief.job.displayCode}'
                : '${brief.partner!.name}: ${exception.title} '
                    'on ${brief.job.displayCode}',
            severity: exception.severity,
            jobId: brief.job.id,
            ctaLabel: 'Follow Up',
            ctaRoute: Paths.job(brief.job.id),
          );
    } on DhFailure catch (_) {
      // Intentionally ignored — see the doc comment.
    }
  }

  // -------------------------------------------------------------- plumbing

  void _assertCastingStage(PartnerJobBrief brief) {
    if (brief.stage.stage == LifecycleStage.casting) return;
    throw RuleViolation(
      message: 'This is the ${brief.stage.stage.label} stage. Casting paperwork belongs on a '
          'casting stage.',
      detail: 'stage=${brief.stage.stage.wire}',
      code: 'not_a_casting_stage',
    );
  }

  /// Turn an RLS refusal on `casting_params` into a sentence the caster can act on.
  ///
  /// See the library comment for why it happens. Two facts have to survive the translation: what
  /// is missing in the database, and — when a file was involved — that the upload itself
  /// succeeded. A caster told only "permission denied" would photograph the tree again.
  static DhFailure _translateCastingWrite(DhFailure failure, {required bool uploaded}) {
    final refused = failure is PermissionDenied ||
        failure.code == SqlState.insufficientPrivilege ||
        (failure.detail?.contains('row-level security') ?? false);
    if (!refused) return failure;

    return PermissionDenied(
      message: uploaded
          ? 'The photo is uploaded and attached to the job, but this build cannot record it as '
              'the casting evidence — the database only lets internal staff update '
              'casting_params. Tell the workshop; they can tick it off from their side.'
          : 'This build cannot save casting notes from a vendor account — the database only lets '
              'internal staff update casting_params. Report it as an issue instead and the '
              'workshop will record it.',
      detail: 'Add a partner UPDATE policy on casting_params limited to '
          '(photo_id, tree_weight_g, notes), or expose fn_attach_casting_photo as security '
          'definer. ${failure.detail ?? failure.message}',
      code: failure.code,
    );
  }

  /// Invalidated even on failure: `attachCastingPhoto` uploads before it can be refused, so the
  /// screen must re-read rather than keep showing "no evidence yet".
  ///
  /// `casting_params` is not on the job realtime channel, so nothing brings it back on its own.
  void _refresh(String jobId) {
    ref
      ..invalidate(partnerJobBriefProvider(jobId))
      ..invalidate(partnerQueueLiveProvider)
      ..invalidate(castingParamsProvider(jobId))
      ..invalidate(jobSnapshotProvider(jobId));
  }

  /// A thread post that accompanies a vendor action.
  ///
  /// Internal on purpose. This is shop talk between the workshop and its foundry — temperatures,
  /// tree weights, a delay — and the mockups ran one feed for everybody, which made exactly that
  /// chatter customer-visible by default. The customer still sees the progress: closing a stage
  /// writes an `activity_events` row by trigger, and events are never internal because the audit
  /// trail is what the customer is entitled to.
  ///
  /// Best effort. The action itself is already recorded; a post that did not land must not turn a
  /// completed stage into a reported failure.
  Future<void> _note({
    required String jobId,
    required LifecycleStage stage,
    required String body,
  }) async {
    try {
      await ref.read(threadRepositoryProvider).postMessage(
            jobId: jobId,
            body: body,
            stage: stage,
            isInternal: true,
          );
    } on DhFailure catch (_) {
      // Intentionally ignored — see the doc comment.
    }
  }
}
