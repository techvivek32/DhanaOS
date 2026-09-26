/// The designer's side of a revision request. NEW — the corpus had no such screen, which is why
/// its CAD loop was not a loop at all.
///
/// `cad_review` could reject a version and `caster_dashboard` could receive an approved one.
/// Between those two facts sat an unrepresented person: the designer who has to read the
/// rejection, work out which prong the reviewer meant, redraw it and say what they did. D-011
/// rule 2 exists to make sure that person is given a reason — and then the corpus never showed
/// them the reason.
///
/// So this screen has one job: turn a `cad_reviews` row with `approved = false` into work a
/// designer can close. The reviewer's words at the top, their pins on the render they were
/// pointing at, a tick against each one as it is dealt with, and a single way forward — the next
/// version.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/cad/cad_actions.dart';
import 'package:dhanaos/features/cad/cad_gateway.dart';
import 'package:dhanaos/features/cad/revision_upload.dart';
import 'package:dhanaos/features/cad/widgets/cad_widgets.dart';
import 'package:dhanaos/features/cad/widgets/render_canvas.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class RevisionResponseScreen extends ConsumerStatefulWidget {
  const RevisionResponseScreen({super.key, required this.revisionId});

  /// The revision that was sent back — not the one being drawn. The request is attached to the
  /// version it judged.
  final String revisionId;

  static Future<void> push(BuildContext context, String revisionId) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RevisionResponseScreen(revisionId: revisionId),
        ),
      );

  @override
  ConsumerState<RevisionResponseScreen> createState() => _RevisionResponseScreenState();
}

class _RevisionResponseScreenState extends ConsumerState<RevisionResponseScreen> {
  String? _selectedPin;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(cadReviewBundleProvider(widget.revisionId));

    return async.when(
      loading: () => const _Frame(
        child: Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoadingSkeleton(height: 64),
              SizedBox(height: Spacing.md),
              LoadingSkeleton(height: 240, radius: Radii.rMd),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.lines(),
            ],
          ),
        ),
      ),
      error: (error, _) => _Frame(
        child: ErrorState(
          title: 'The revision request did not open',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read the version that was sent back.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(cadReviewBundleProvider(widget.revisionId)),
        ),
      ),
      data: _loaded,
    );
  }

  Widget _loaded(CadReviewBundle bundle) {
    final request = bundle.openRevisionRequest;
    final task = ref.watch(cadActionsProvider);
    final busy = task != null;
    final render = bundle.currentRenders.isEmpty ? null : bundle.currentRenders.first;
    final url = render == null ? null : bundle.files.url(render.id);
    final image = url == null ? null : NetworkImage(url);

    return Scaffold(
      appBar: AppBar(
        title: Text('Revise ${bundle.revision.version}'),
        actions: [
          IconButton(
            onPressed: busy
                ? null
                : () => ref.invalidate(cadReviewBundleProvider(widget.revisionId)),
            tooltip: 'Re-read the request',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(cadReviewBundleProvider(widget.revisionId).future),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xl),
          children: [
            DhCard(
              child: CadJobLine(
                code: bundle.job.displayCode,
                title: bundle.job.displayTitle,
                priority: bundle.job.priority,
                trailing: CadStateChip(bundle.workState, dense: true),
              ),
            ),
            const SizedBox(height: Spacing.md),
            _request(bundle, request),
            const SizedBox(height: Spacing.md),
            _theVersion(bundle, image: image, render: render),
            const SizedBox(height: Spacing.md),
            _pins(bundle, busy: busy),
            const SizedBox(height: Spacing.md),
            _whatWasOffered(bundle),
          ],
        ),
      ),
      bottomNavigationBar: _footer(bundle, request, task: task),
    );
  }

  // -------------------------------------------------------------- the request

  Widget _request(CadReviewBundle bundle, CadReview? request) {
    if (request == null) {
      final approved = bundle.lastDecision?.approved ?? false;
      return DhSectionCard(
        title: 'No open revision request',
        child: CadNote(
          tone: approved ? CadNoteTone.good : CadNoteTone.info,
          text: approved
              ? '${bundle.revision.version} was approved, not sent back. Nothing here needs '
                  'redrawing — offer a new version only if the design has to change again.'
              : '${bundle.revision.version} has no decision on it yet. It is with the reviewer; '
                  'there is nothing for you to answer until they press something.',
        ),
      );
    }

    return DhSectionCard(
      title: 'What the reviewer asked for',
      subtitle: 'Recorded against ${bundle.revision.version} and kept — a request is never '
          'edited away.',
      child: DecisionTile(
        review: request,
        reviewerName: bundle.nameFor(request.reviewerId),
        version: bundle.revision.version,
      ),
    );
  }

  // -------------------------------------------------------------- the render

  Widget _theVersion(
    CadReviewBundle bundle, {
    required ImageProvider? image,
    required Attachment? render,
  }) {
    return DhSectionCard(
      title: 'Where they were pointing',
      subtitle: bundle.annotations.isEmpty
          ? 'No pins were dropped on this version — the note above is the whole request.'
          : 'Tap a pin to highlight what it says.',
      child: RenderPane(
        version: bundle.revision.version,
        role: RenderRole.current,
        image: image,
        caption: render == null ? null : '${render.filename} · ${render.metaLabel}',
        pins: bundle.annotations,
        selectedPinId: _selectedPin,
        onPinTap: (pin) => setState(
          () => _selectedPin = _selectedPin == pin.id ? null : pin.id,
        ),
        onExpand: image == null
            ? null
            : () => openRenderViewer(
                  context,
                  image: image,
                  title: bundle.revision.version,
                ),
        emptyMessage: 'This version has no render on file, so there is nothing to point at. The '
            'request above is all there is.',
      ),
    );
  }

  // -------------------------------------------------------------- pins

  Widget _pins(CadReviewBundle bundle, {required bool busy}) {
    final pins = bundle.annotations;
    if (pins.isEmpty) return const SizedBox.shrink();

    final open = bundle.openAnnotations.length;

    return DhSectionCard(
      title: 'Points to address',
      subtitle: '${bundle.resolvedAnnotationCount} of ${pins.length} ticked off',
      action: StatusChip(
        label: open == 0 ? 'All addressed' : '$open open',
        tone: open == 0 ? ChipTone.success : ChipTone.warning,
        dense: true,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < pins.length; i++) ...[
            if (i > 0) const SizedBox(height: Spacing.sm),
            AnnotationTile(
              number: i + 1,
              pin: pins[i],
              authorName: bundle.nameFor(pins[i].authorId, fallback: 'Unknown author'),
              selected: _selectedPin == pins[i].id,
              busy: busy,
              onTap: () => setState(
                () => _selectedPin = _selectedPin == pins[i].id ? null : pins[i].id,
              ),
              onResolve: () => unawaited(_resolve(pins[i])),
            ),
          ],
          const SizedBox(height: Spacing.sm + Spacing.xs),
          const CadNote(
            text: 'Ticking a point off records that you dealt with it. Points left open stay on '
                'the version as unaddressed, which is exactly what the next reviewer will look '
                'for.',
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- context

  Widget _whatWasOffered(CadReviewBundle bundle) {
    final note = bundle.revision.designerNote?.trim();

    return DhSectionCard(
      title: 'What ${bundle.revision.version} claimed to change',
      subtitle: 'Your own note from last time, so the next one can pick up where it left off.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SpecDiffTable(
            diff: bundle.revision.specDiff,
            emptyNote: 'No change list was recorded on this version, which is part of why the '
                'reviewer had to describe the problem in prose.',
          ),
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            Text(
              'YOUR NOTE ON ${bundle.revision.version.toUpperCase()}',
              style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              note,
              style: context.text.bodyMedium?.copyWith(color: context.scheme.onSurface),
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------- footer

  Widget _footer(CadReviewBundle bundle, CadReview? request, {required CadTask? task}) {
    final busy = task != null;

    if (bundle.isSettled) {
      return CadFooter(
        note: '${bundle.revision.version} is locked. A new version is the only way to change the '
            'design now.',
        children: [
          FilledButton.icon(
            onPressed: busy
                ? null
                : () => unawaited(_startNext(bundle, request)),
            icon: const Icon(Icons.upload_file_rounded, size: 18),
            label: const Text('Offer a new version'),
          ),
        ],
      );
    }

    return CadFooter(
      note: bundle.openAnnotations.isEmpty
          ? null
          : '${bundle.openAnnotations.length} point'
              '${bundle.openAnnotations.length == 1 ? '' : 's'} still open. You can offer the '
              'next version anyway — they stay on the record.',
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => unawaited(_ask(bundle)),
                icon: task == CadTask.reply
                    ? const _Spinner()
                    : const Icon(Icons.forum_outlined, size: 18),
                label: const Text('Ask a question'),
              ),
            ),
            const SizedBox(width: Spacing.sm + Spacing.xs),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : () => unawaited(_startNext(bundle, request)),
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: const Text('Next version'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // -------------------------------------------------------------- actions

  Future<void> _resolve(CadAnnotation pin) async {
    try {
      await ref.read(cadActionsProvider.notifier).resolvePin(
            revisionId: widget.revisionId,
            annotationId: pin.id,
          );
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  /// Hand the reviewer's own words forward into the upload screen, so the designer writes their
  /// account with the request still in front of them.
  Future<void> _startNext(CadReviewBundle bundle, CadReview? request) async {
    final created = await RevisionUploadScreen.push(
      context,
      jobId: bundle.job.id,
      answeringVersion: bundle.revision.version,
      answeringComment: request?.comment?.trim(),
    );
    if (created == null || !mounted) return;

    // This screen is about a version that has just been superseded. Leaving it open would show
    // the designer a request they have already answered, so it closes and the queue — which is
    // live — picks the new version up as awaiting review.
    Navigator.of(context).pop();
  }

  Future<void> _ask(CadReviewBundle bundle) async {
    final text = await promptForText(
      context,
      title: 'Ask about ${bundle.revision.version}',
      message: 'This goes into the job thread as an internal post, so the answer lands where the '
          'rest of the job history is rather than in a phone call nobody can read back.',
      fieldLabel: 'Your question',
      submitLabel: 'Post the question',
      hint: 'Do you want the halo tightened as well, or only the melee size?',
    );
    if (text == null || !mounted) return;

    try {
      await ref.read(cadActionsProvider.notifier).reply(
            jobId: bundle.job.id,
            body: text,
            stage: bundle.rail.activeLifecycle,
          );
      if (!mounted) return;
      showDone(context, 'Posted to the job thread.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }
}

// ================================================================= chrome

final class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Revision request')),
        body: child,
      );
}

final class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
}
