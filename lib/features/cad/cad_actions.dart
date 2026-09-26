/// Every write the CAD loop makes, in one place, with one busy flag.
///
/// The rule that shapes this file is D-011 rule 2, and the shape is *deliberately asymmetric*:
/// approving a design needs no words, rejecting one owes the designer a reason. The rule itself
/// lives in Postgres as `cad_reject_needs_comment` and is pre-rendered in the UI as a held
/// button; nothing here re-implements it, because a rule implemented three times is a rule that
/// will disagree with itself.
///
/// Two consequences are handled here rather than at a call site:
///
///  * **An approval is two writes.** `cad_reviews` records the decision and locks the revision;
///    `fn_complete_stage` moves the rail. If the second fails the first still happened, and the
///    operator has to be told exactly that — not "approval failed", which would send them back
///    to press an approval that already exists.
///  * **A rejection does not walk the job backwards.** Stage history is append-only (D-005) and
///    there is no function to un-complete a stage. The rejection row *is* what puts the job back
///    on the designer's queue, via [CadWorkState.revisionsRequested].
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
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/features/cad/cad_gateway.dart';

part 'cad_actions.g.dart';

/// Which CAD write is in flight, so the screen can spin the button that was actually pressed
/// rather than greying out every control it owns.
enum CadTask {
  approve,
  requestRevisions,
  offerRevision,
  assign,
  pin,
  resolvePin,
  reply,
}

/// One file on its way into a revision.
final class CadUpload {
  const CadUpload({required this.file, required this.filename, required this.kind});

  /// A render picked from the camera roll or the file picker.
  factory CadUpload.render(File file, {String? filename}) => CadUpload(
        file: file,
        filename: filename ?? _basename(file.path),
        kind: AttachmentKind.cadRender,
      );

  /// The STL / STEP the caster downloads. `CadRevision.hasModel` is what tells a caster the
  /// revision is manufacturable at all.
  factory CadUpload.model(File file, {String? filename}) => CadUpload(
        file: file,
        filename: filename ?? _basename(file.path),
        kind: AttachmentKind.stl,
      );

  final File file;
  final String filename;
  final AttachmentKind kind;

  /// A stable key for a file that has no attachment id yet, so a tile keeps its identity while
  /// the operator reorders or removes its neighbours.
  String get localKey => file.path;

  static String _basename(String path) => path.split(RegExp(r'[\\/]')).last;
}

/// Where a multi-file offer has got to. Rendered in the footer: an operator on shop Wi-Fi
/// watching a 40 MB mesh needs to know it is moving.
final class CadUploadProgress {
  const CadUploadProgress({required this.done, required this.total, required this.filename});

  final int done;
  final int total;
  final String filename;

  double get fraction => total == 0 ? 0 : (done / total).clamp(0.0, 1.0);

  /// 'Uploading 2 of 3 — cad_mesh_v2.png'.
  String get label => 'Uploading ${done + 1} of $total — $filename';
}

// ================================================================= actions

/// Kept alive for the same reason `BoardMoves` is: an upload or an approval must survive the
/// operator flicking to another screen while the round trip is open. An auto-disposed notifier
/// would be torn down under its own `finally`.
@Riverpod(keepAlive: true)
class CadActions extends _$CadActions {
  /// Null when nothing is in flight.
  @override
  CadTask? build() => null;

  bool get isBusy => state != null;

  bool isRunning(CadTask task) => state == task;

  // -------------------------------------------------------------- the decision

  /// Approve the revision, lock it, and move the job on.
  ///
  /// D-011 rule 2: no comment is required to approve. One is still accepted, because "approved,
  /// but tighten the prong height at the bench" is a real thing a reviewer says.
  ///
  /// The lock is `submitCadReview`'s job — a customer who approved v2.0 must never later be
  /// shown a changed v2.0. The advance is `fn_complete_stage`'s, and only when the job is
  /// standing somewhere a CAD approval closes ([CadReviewBundle.stageToClose]).
  Future<void> approve({required CadReviewBundle bundle, String? comment}) async {
    state = CadTask.approve;
    final revision = bundle.revision;
    try {
      await ref
          .read(productionRepositoryProvider)
          .submitCadReview(revisionId: revision.id, approved: true, comment: comment);

      final closing = bundle.stageToClose;
      if (closing != null) {
        try {
          await ref.read(jobRepositoryProvider).completeStage(
                jobId: bundle.job.id,
                stage: closing.stage,
                notes: 'CAD ${revision.version} approved.',
              );
        } on DhFailure catch (failure, stack) {
          // The review row is written and the version is locked. Reporting a bare "could not
          // approve" here would send the reviewer back to press an approval that already exists.
          Error.throwWithStackTrace(
            RuleViolation(
              message: '${revision.version} is approved and locked, but the job did not move on: '
                  '${failure.message}',
              detail: failure.detail,
              code: failure.code,
            ),
            stack,
          );
        }
      }

      await _note(
        jobId: bundle.job.id,
        stage: closing?.stage ?? LifecycleStage.cad,
        // The customer approves designs, so a version being signed off is theirs to see.
        isInternal: false,
        body: _approvalNote(revision, comment),
      );
    } finally {
      state = null;
      _afterDecision(bundle);
    }
  }

  static String _approvalNote(CadRevision revision, String? comment) {
    final note = comment?.trim();
    final head = 'CAD ${revision.version} approved and locked.';
    return note == null || note.isEmpty ? head : '$head\n\n$note';
  }

  /// Send the revision back with a reason.
  ///
  /// D-011 rule 2's other half. `cad_reject_needs_comment` refuses an empty comment in Postgres
  /// and the button is held shut in the UI, so this method does not pre-check: one rule, two
  /// places that render it, zero places that re-decide it.
  Future<void> requestRevisions({
    required CadReviewBundle bundle,
    required String comment,
  }) async {
    state = CadTask.requestRevisions;
    try {
      await ref.read(productionRepositoryProvider).submitCadReview(
            revisionId: bundle.revision.id,
            approved: false,
            comment: comment,
          );
      await _note(
        jobId: bundle.job.id,
        stage: bundle.rail.activeLifecycle ?? LifecycleStage.cad,
        // Criticism of a version in progress is shop talk, not a customer update.
        isInternal: true,
        body: 'Revisions requested on ${bundle.revision.version}.\n\n${comment.trim()}',
      );
    } finally {
      state = null;
      _afterDecision(bundle);
    }
  }

  void _afterDecision(CadReviewBundle bundle) {
    // Invalidated even on failure: `submitCadReview` writes the review row before the advance
    // can fail, so the screen must re-read rather than keep showing an open decision.
    ref.invalidate(cadReviewBundleProvider(bundle.revision.id));
    ref.invalidate(jobSnapshotProvider(bundle.job.id));
    ref.invalidate(cadRevisionsProvider(bundle.job.id));
    ref.invalidate(currentCadRevisionProvider(bundle.job.id));
    ref.invalidate(revisionContextProvider(bundle.job.id));
  }

  // -------------------------------------------------------------- annotations

  /// Drop a pin at a point on the render.
  ///
  /// Percentages, not pixels — the same pin has to land on the same prong on a phone and on a
  /// workstation. An empty note is refused by the repository: a pin with no words tells the
  /// designer where to look and nothing else.
  Future<void> dropPin({
    required String revisionId,
    required double xPct,
    required double yPct,
    required String body,
  }) async {
    state = CadTask.pin;
    try {
      await ref.read(productionRepositoryProvider).addCadAnnotation(
            revisionId: revisionId,
            xPct: xPct,
            yPct: yPct,
            body: body,
          );
    } finally {
      state = null;
      ref.invalidate(cadReviewBundleProvider(revisionId));
    }
  }

  /// Mark one pin addressed. The designer ticks these off as they redraw, so the next reviewer
  /// can see which remarks were acted on and which were not.
  Future<void> resolvePin({required String revisionId, required String annotationId}) async {
    state = CadTask.resolvePin;
    try {
      await ref.read(productionRepositoryProvider).resolveCadAnnotation(annotationId);
    } finally {
      state = null;
      ref.invalidate(cadReviewBundleProvider(revisionId));
    }
  }

  // -------------------------------------------------------------- new revision

  /// Upload the files, then offer them as a new revision.
  ///
  /// The files go up **before** the row, deliberately. `createCadRevision` clears `is_current` on
  /// the old revision before inserting the new one, so a failure between those two writes leaves
  /// a job with nothing current — which reads as "nothing to review". Uploading first means a
  /// storage failure is caught while the old revision is still standing. The cost is that a
  /// failure after the uploads leaves the files on the job as loose entries in Project Files:
  /// visible and re-usable, not lost.
  Future<CadRevision> offerRevision({
    required String jobId,
    required String version,
    required List<CadUpload> renders,
    CadUpload? model,
    String? designerNote,
    Map<String, String> specDiff = const <String, String>{},
    void Function(CadUploadProgress progress)? onProgress,
  }) async {
    state = CadTask.offerRevision;
    try {
      final orgId = ref.read(repoIdentityProvider).requireOrgId();
      final store = ref.read(attachmentStoreProvider);
      final queue = <CadUpload>[...renders, if (model != null) model];

      final renderIds = <String>[];
      String? modelId;
      for (var i = 0; i < queue.length; i++) {
        final upload = queue[i];
        onProgress?.call(
          CadUploadProgress(done: i, total: queue.length, filename: upload.filename),
        );
        final attachment = await _put(store, upload, orgId: orgId, jobId: jobId);
        if (upload.kind == AttachmentKind.stl) {
          modelId = attachment.id;
        } else {
          renderIds.add(attachment.id);
        }
      }

      final revision = await ref.read(productionRepositoryProvider).createCadRevision(
            jobId: jobId,
            version: version,
            designerNote: designerNote,
            renderIds: renderIds,
            modelId: modelId,
            specDiff: specDiff,
          );

      await _note(
        jobId: jobId,
        stage: LifecycleStage.cad,
        isInternal: false,
        body: _offerNote(revision, designerNote, specDiff),
      );
      return revision;
    } finally {
      state = null;
      ref.invalidate(revisionContextProvider(jobId));
      ref.invalidate(cadRevisionsProvider(jobId));
      ref.invalidate(currentCadRevisionProvider(jobId));
    }
  }

  /// One file away, with the failure naming the file. "Upload failed" on a four-render offer is
  /// not something an operator can act on.
  Future<Attachment> _put(
    AttachmentStore store,
    CadUpload upload, {
    required String orgId,
    required String jobId,
  }) async {
    try {
      return await store.upload(
        UploadRequest.file(
          orgId: orgId,
          kind: upload.kind,
          file: upload.file,
          filename: upload.filename,
          jobId: jobId,
        ),
      );
    } on DhFailure catch (failure, stack) {
      Error.throwWithStackTrace(
        StorageFailure(
          message: '${upload.filename} did not upload: ${failure.message}',
          detail: failure.detail,
          code: failure.code,
        ),
        stack,
      );
    }
  }

  static String _offerNote(
    CadRevision revision,
    String? designerNote,
    Map<String, String> specDiff,
  ) {
    final lines = <String>['CAD ${revision.version} offered for review.'];
    final note = designerNote?.trim();
    if (note != null && note.isNotEmpty) lines.add(note);
    if (specDiff.isNotEmpty) {
      lines.add(
        specDiff.entries.map((entry) => '• ${entry.key}: ${entry.value}').join('\n'),
      );
    }
    return lines.join('\n\n');
  }

  // -------------------------------------------------------------- assignment

  /// Put the CAD in somebody's hands.
  ///
  /// [stage] is the rail row the assignment is written to, because `v_job_list.assigned_to`
  /// joins the *active* stage: writing an assignment onto `cad` while the job stands at
  /// `approval` would be a record nobody's queue ever reads. Use [stageFor].
  Future<void> assignDesigner({
    required String jobId,
    required String userId,
    LifecycleStage stage = LifecycleStage.cad,
    DateTime? expectedAt,
  }) async {
    state = CadTask.assign;
    try {
      await ref.read(jobRepositoryProvider).assignStage(
            jobId: jobId,
            stage: stage,
            assignedTo: Opt(userId),
            expectedAt: expectedAt == null ? null : Opt(expectedAt),
          );
    } finally {
      state = null;
      ref.invalidate(jobSnapshotProvider(jobId));
      ref.invalidate(stageRailProvider(jobId));
    }
  }

  /// Hand the job back to nobody.
  ///
  /// `Opt.clear()` rather than an omitted argument: omitting leaves the column alone, and the
  /// point here is to write SQL NULL so the row stops matching anybody's queue.
  Future<void> unassign({
    required String jobId,
    LifecycleStage stage = LifecycleStage.cad,
  }) async {
    state = CadTask.assign;
    try {
      await ref.read(jobRepositoryProvider).assignStage(
            jobId: jobId,
            stage: stage,
            assignedTo: const Opt<String>.clear(),
          );
    } finally {
      state = null;
      ref.invalidate(jobSnapshotProvider(jobId));
      ref.invalidate(stageRailProvider(jobId));
    }
  }

  /// Take the job yourself, which is what a designer standing in front of an unclaimed job
  /// actually wants to do.
  Future<void> claim({
    required String jobId,
    LifecycleStage stage = LifecycleStage.cad,
  }) async {
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) {
      throw const PermissionDenied(
        message: 'Your session ended. Sign in again to take this job.',
        code: 'no_session',
        sessionExpired: true,
      );
    }
    await assignDesigner(jobId: jobId, userId: me.id, stage: stage);
  }

  /// The rail row a CAD assignment belongs on.
  static LifecycleStage stageFor(LifecycleStage? current) =>
      current == LifecycleStage.approval ? LifecycleStage.approval : LifecycleStage.cad;

  // -------------------------------------------------------------- thread

  /// Post a question back to whoever asked for the revisions, so the loop has somewhere to
  /// happen other than a phone call nobody can read six weeks later.
  Future<void> reply({
    required String jobId,
    required String body,
    LifecycleStage? stage,
  }) async {
    state = CadTask.reply;
    try {
      await ref.read(threadRepositoryProvider).postMessage(
            jobId: jobId,
            body: body,
            stage: stage,
            isInternal: true,
          );
    } finally {
      state = null;
    }
  }

  /// A thread post that accompanies a decision, best effort.
  ///
  /// The decision itself is already in `cad_reviews` and `activity_events`. A thread post that
  /// did not land must not turn a completed, irreversible approval into a reported failure — so
  /// this swallows its own error rather than unwinding the caller.
  Future<void> _note({
    required String jobId,
    required String body,
    required bool isInternal,
    LifecycleStage? stage,
  }) async {
    try {
      await ref.read(threadRepositoryProvider).postMessage(
            jobId: jobId,
            body: body,
            stage: stage,
            isInternal: isInternal,
          );
    } on DhFailure catch (_) {
      // Intentionally ignored — see the doc comment.
    }
  }
}
