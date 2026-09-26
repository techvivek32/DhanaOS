/// The CAD decision. A rebuild of `cad_review_dh_1048`, which was the best screen in the corpus.
///
/// What the source got right and is kept verbatim:
///
///  * **D-011 rule 2 — the asymmetric decision.** "Request Revisions" is blocked while the
///    comment is empty; "Approve" is not. Rejection owes the designer a reason. The mockup
///    enforced it by flashing an error ring and rewriting the placeholder for two seconds, and
///    that instinct was right: the button stays *live* so that pressing it produces an
///    explanation and puts the cursor in the field. A greyed-out button would have taught the
///    operator nothing. `cad_reject_needs_comment` carries the same rule in Postgres, so a
///    rewrite of this file cannot weaken it.
///  * Pins that sit **on** the geometry under discussion rather than in a list beside it.
///
/// What it did not have, and a real review needs:
///
///  * The previous version to compare against. One image and a sentence of prose is not a review.
///  * The version's change list as data (`cad_revisions.spec_diff`) instead of prose.
///  * A settled state. The mockup's decision buttons stayed live forever; here an approved
///    revision is locked and the screen becomes the record of what was agreed, because a customer
///    who approved v2.0 must never be shown a changed v2.0.
///  * Anything at all for the designer on the other side of the rejection — see
///    `revision_response.dart`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/cad/cad_actions.dart';
import 'package:dhanaos/features/cad/cad_gateway.dart';
import 'package:dhanaos/features/cad/revision_upload.dart';
import 'package:dhanaos/features/cad/widgets/cad_widgets.dart';
import 'package:dhanaos/features/cad/widgets/render_canvas.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// Which panes the compare section shows.
enum _Panes {
  compare('Compare', Icons.compare_rounded),
  current('Current', Icons.view_in_ar_outlined),
  previous('Previous', Icons.history_rounded);

  const _Panes(this.label, this.icon);

  final String label;
  final IconData icon;
}

final class CadReviewScreen extends ConsumerStatefulWidget {
  const CadReviewScreen({super.key, required this.revisionId});

  /// `cad_revisions.id`. The route is `/cad/:revisionId` — a review is addressed by the version
  /// being decided, not by the job, so a link in a message opens the exact thing that was
  /// approved.
  final String revisionId;

  /// Open the review from a queue row, keeping the operator's place behind them.
  static Future<void> push(BuildContext context, String revisionId) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CadReviewScreen(revisionId: revisionId),
        ),
      );

  @override
  ConsumerState<CadReviewScreen> createState() => _CadReviewScreenState();
}

class _CadReviewScreenState extends ConsumerState<CadReviewScreen> {
  final _comment = TextEditingController();
  final _commentFocus = FocusNode();
  final _commentKey = GlobalKey();
  final _scroll = ScrollController();

  /// D-011 rule 2's visible half: set when the operator pressed "Request Revisions" with nothing
  /// typed. Cleared the moment they type, so the error never outlives the mistake.
  String? _commentError;

  _Panes _panes = _Panes.compare;
  String? _selectedPin;
  bool _placingPin = false;

  @override
  void initState() {
    super.initState();
    _comment.addListener(_clearErrorOnType);
  }

  @override
  void dispose() {
    _comment
      ..removeListener(_clearErrorOnType)
      ..dispose();
    _commentFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _clearErrorOnType() {
    if (_commentError != null && _comment.text.trim().isNotEmpty) {
      setState(() => _commentError = null);
    }
  }

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
              LoadingSkeleton(height: 56),
              SizedBox(height: Spacing.md),
              LoadingSkeleton(height: 260, radius: Radii.rMd),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
            ],
          ),
        ),
      ),
      error: (error, _) => _Frame(
        child: ErrorState(
          title: 'This CAD review did not open',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read the revision. Check the connection and try again.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(cadReviewBundleProvider(widget.revisionId)),
        ),
      ),
      data: _loaded,
    );
  }

  // -------------------------------------------------------------- loaded

  Widget _loaded(CadReviewBundle bundle) {
    final permissions = ref.watch(permissionsProvider);
    final task = ref.watch(cadActionsProvider);
    final busy = task != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('CAD Review'),
        actions: [
          IconButton(
            onPressed: busy
                ? null
                : () => ref.invalidate(cadReviewBundleProvider(widget.revisionId)),
            tooltip: 'Re-read this revision',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(cadReviewBundleProvider(widget.revisionId).future),
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xl),
          children: [
            _header(bundle),
            const SizedBox(height: Spacing.md),
            if (bundle.rail.isSeeded) ...[
              JobStageRail.compact(nodes: _railNodes(bundle)),
              const SizedBox(height: Spacing.md),
            ],
            if (bundle.isSettled) ...[
              _settledNote(bundle),
              const SizedBox(height: Spacing.md),
            ],
            _renders(bundle),
            const SizedBox(height: Spacing.md),
            _annotations(bundle, busy: busy),
            const SizedBox(height: Spacing.md),
            _changes(bundle),
            const SizedBox(height: Spacing.md),
            if (!bundle.isSettled) ...[
              _decisionBlock(bundle, permissions: permissions, busy: busy),
              const SizedBox(height: Spacing.md),
            ],
            _history(bundle),
          ],
        ),
      ),
      bottomNavigationBar: bundle.isSettled
          ? _settledFooter(bundle)
          : _decisionFooter(bundle, permissions: permissions, task: task),
    );
  }

  List<StageNode> _railNodes(CadReviewBundle bundle) => [
        for (final row in bundle.rail.stages)
          StageNode(
            stage: row.stage,
            state: row.state,
            detail: row.isActive ? row.dwellLabel : null,
            isLate: row.isLate,
            withPartner: row.isWithPartner,
          ),
      ];

  Widget _header(CadReviewBundle bundle) {
    final designer = bundle.designer;

    return DhCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CadJobLine(
            code: bundle.job.displayCode,
            title: bundle.job.displayTitle,
            priority: bundle.job.priority,
            trailing: CadStateChip(bundle.workState, dense: true),
          ),
          const SizedBox(height: Spacing.md),
          DataPairGrid(
            children: [
              DataPair.mono(
                label: 'Version',
                value: bundle.revision.version,
                emphasis: DataEmphasis.strong,
              ),
              DataPair(
                label: 'Designer',
                value: designer?.fullName ?? 'Unassigned',
                icon: Icons.draw_outlined,
              ),
              DataPair.timestamp(label: 'Offered', utc: bundle.revision.createdAt),
              DataPair.mono(
                label: 'Open pins',
                value: '${bundle.openAnnotations.length}'
                    '${bundle.annotations.isEmpty ? '' : ' / ${bundle.annotations.length}'}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _settledNote(CadReviewBundle bundle) {
    final decision = bundle.lastDecision;
    if (decision != null && decision.approved) {
      return CadNote(
        tone: CadNoteTone.good,
        icon: Icons.lock_outline_rounded,
        text: '${bundle.revision.version} was approved by '
            '${bundle.nameFor(decision.reviewerId)} on ${localStamp(decision.createdAt)} and is '
            'locked. It is the design of record — reviewing it again would rewrite history, so '
            'the decision is shown rather than offered.',
      );
    }
    return CadNote(
      tone: CadNoteTone.info,
      icon: Icons.lock_outline_rounded,
      text: '${bundle.revision.version} is locked and can no longer be decided here.',
    );
  }

  // -------------------------------------------------------------- renders

  Widget _renders(CadReviewBundle bundle) {
    final current = bundle.currentRenders;
    final previous = bundle.previousRenders;
    final canCompare = bundle.canCompare;
    final mode = canCompare ? _panes : _Panes.current;

    return DhSectionCard(
      title: 'The design',
      subtitle: canCompare
          ? 'Compare ${bundle.previous!.version} with ${bundle.revision.version}. Tap a pin to '
              'read it.'
          : 'The first version on this job — there is nothing to compare it against yet.',
      action: canCompare
          ? null
          : const StatusChip(label: 'First offer', tone: ChipTone.neutral, dense: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (canCompare) ...[
            DhSegmented<_Panes>(
              value: mode,
              segments: [
                for (final option in _Panes.values)
                  DhSegment(value: option, label: option.label, icon: option.icon),
              ],
              onChanged: (value) => setState(() {
                _panes = value;
                // A pin is placed against the current geometry. Leaving placement armed while
                // the previous version is on screen would drop it on the wrong image.
                if (value != _Panes.current) _placingPin = false;
              }),
            ),
            const SizedBox(height: Spacing.md),
          ],
          if (_placingPin) ...[
            CadNote(
              tone: CadNoteTone.consequence,
              icon: Icons.touch_app_outlined,
              text: 'Tap the render where the change is needed.',
              action: TextButton(
                onPressed: () => setState(() => _placingPin = false),
                child: const Text('Stop placing'),
              ),
            ),
            const SizedBox(height: Spacing.md),
          ],
          _panesFor(bundle, mode, current, previous),
          if (current.length > 1) ...[
            const SizedBox(height: Spacing.md),
            Text(
              'OTHER VIEWS OF ${bundle.revision.version}',
              style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.sm),
            AttachmentGrid(
              items: [
                for (final render in current.skip(1))
                  attachmentViewOf(render, signedUrl: bundle.files.url(render.id)),
              ],
              onOpen: (view) => _openFullScreen(bundle, view.id),
            ),
          ],
        ],
      ),
    );
  }

  Widget _panesFor(
    CadReviewBundle bundle,
    _Panes mode,
    List<Attachment> current,
    List<Attachment> previous,
  ) {
    final currentPane = _pane(
      bundle,
      version: bundle.revision.version,
      role: RenderRole.current,
      render: current.isEmpty ? null : current.first,
      withPins: true,
    );

    if (mode == _Panes.current) return currentPane;

    final previousPane = _pane(
      bundle,
      version: bundle.previous?.version ?? '—',
      role: RenderRole.previous,
      render: previous.isEmpty ? null : previous.first,
      withPins: false,
    );

    if (mode == _Panes.previous) return previousPane;

    // Side by side on anything wide enough to make two panes legible; stacked on a phone, where
    // two 160px-wide renders would be decoration rather than a comparison.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 520) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              previousPane,
              const SizedBox(height: Spacing.md),
              currentPane,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: previousPane),
            const SizedBox(width: Spacing.md),
            Expanded(child: currentPane),
          ],
        );
      },
    );
  }

  Widget _pane(
    CadReviewBundle bundle, {
    required String version,
    required RenderRole role,
    required Attachment? render,
    required bool withPins,
  }) {
    final url = render == null ? null : bundle.files.url(render.id);
    final image = url == null ? null : NetworkImage(url);

    return RenderPane(
      version: version,
      role: role,
      image: image,
      caption: render == null ? null : '${render.filename} · ${render.metaLabel}',
      pins: withPins ? bundle.annotations : const <CadAnnotation>[],
      selectedPinId: _selectedPin,
      dropping: withPins && _placingPin,
      onPinTap: (pin) => setState(
        () => _selectedPin = _selectedPin == pin.id ? null : pin.id,
      ),
      onTapAt: withPins && _placingPin && render != null
          ? (x, y) => _dropPin(bundle, x, y)
          : null,
      onExpand: image == null
          ? null
          : () => openRenderViewer(context, image: image, title: version),
      emptyMessage: role == RenderRole.previous
          ? 'The previous version had no render attached.'
          : 'This version has no render yet. A revision cannot be judged without one — ask the '
              'designer to attach it.',
    );
  }

  void _openFullScreen(CadReviewBundle bundle, String attachmentId) {
    final url = bundle.files.url(attachmentId);
    if (url == null) return;
    unawaited(
      openRenderViewer(
        context,
        image: NetworkImage(url),
        title: bundle.revision.version,
      ),
    );
  }

  // -------------------------------------------------------------- annotations

  Widget _annotations(CadReviewBundle bundle, {required bool busy}) {
    final pins = bundle.annotations;

    return DhSectionCard(
      title: 'Annotations',
      subtitle: pins.isEmpty
          ? null
          : '${bundle.openAnnotations.length} open · ${bundle.resolvedAnnotationCount} addressed',
      action: bundle.isSettled
          ? null
          : TextButton.icon(
              onPressed: busy
                  ? null
                  : () => setState(() {
                        _placingPin = true;
                        _panes = _Panes.current;
                      }),
              icon: const Icon(Icons.add_location_alt_outlined, size: 18),
              label: const Text('Add a pin'),
            ),
      child: pins.isEmpty
          ? const CadNote(
              text: 'No pins on this version. Press "Add a pin", then tap the render where the '
                  'change is needed — a positioned remark saves the designer guessing which '
                  'prong you meant.',
            )
          : Column(
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
                    onResolve: bundle.isSettled ? null : () => _resolvePin(pins[i]),
                  ),
                ],
              ],
            ),
    );
  }

  // -------------------------------------------------------------- what changed

  Widget _changes(CadReviewBundle bundle) {
    final note = bundle.revision.designerNote?.trim();
    final model = bundle.model;

    return DhSectionCard(
      title: 'What changed in ${bundle.revision.version}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SpecDiffTable(diff: bundle.revision.specDiff),
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            Text(
              'DESIGNER NOTE',
              style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              note,
              style: context.text.bodyMedium?.copyWith(color: context.scheme.onSurface),
            ),
          ],
          const SizedBox(height: Spacing.md),
          if (model != null)
            AttachmentTile.row(
              item: attachmentViewOf(model),
            )
          else
            const CadNote(
              tone: CadNoteTone.risk,
              text: 'No STL or STEP is attached to this version. The renders are enough to judge '
                  'the design, but the caster cannot start from a render — the mesh has to land '
                  'before the job reaches wax.',
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- history

  Widget _history(CadReviewBundle bundle) {
    if (bundle.reviews.isEmpty) {
      return const DhSectionCard(
        title: 'Decision history',
        child: CadNote(
          text: 'No decision has been recorded on this version yet. Whatever you press next is '
              'the first row in its audit trail.',
        ),
      );
    }

    return DhSectionCard(
      title: 'Decision history',
      subtitle: 'Append-only. A decision is never edited — a later one is added.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < bundle.reviews.length; i++) ...[
            if (i > 0) const SizedBox(height: Spacing.sm),
            DecisionTile(
              review: bundle.reviews[i],
              reviewerName: bundle.nameFor(bundle.reviews[i].reviewerId),
              version: bundle.revision.version,
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------- the decision

  Widget _decisionBlock(
    CadReviewBundle bundle, {
    required Permissions permissions,
    required bool busy,
  }) {
    return DhSectionCard(
      key: _commentKey,
      title: 'Your decision',
      subtitle: 'Approving locks ${bundle.revision.version}. Sending it back owes the designer '
          'a reason.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _comment,
            focusNode: _commentFocus,
            enabled: !busy,
            minLines: 3,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Note to the designer',
              hintText: 'What has to change, and why. Name the part — "halo melee reads thin at '
                  '1.2mm, take it to 1.5mm".',
              errorText: _commentError,
              helperText: _commentError == null
                  ? 'Required to request revisions. Optional to approve.'
                  : null,
              helperMaxLines: 2,
            ),
          ),
          if (bundle.openAnnotations.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            CadNote(
              tone: CadNoteTone.info,
              icon: Icons.push_pin_outlined,
              text: '${bundle.openAnnotations.length} pin'
                  '${bundle.openAnnotations.length == 1 ? '' : 's'} on this version '
                  '${bundle.openAnnotations.length == 1 ? 'is' : 'are'} still open. Approving '
                  'leaves them on the record as unaddressed.',
            ),
          ],
          if (!permissions.canApproveDesign) ...[
            const SizedBox(height: Spacing.md),
            CadNote(
              tone: CadNoteTone.risk,
              text: permissions.blockReason(Capability.approveDesign) ??
                  'You cannot approve a design on this account.',
            ),
          ],
        ],
      ),
    );
  }

  Widget _decisionFooter(
    CadReviewBundle bundle, {
    required Permissions permissions,
    required CadTask? task,
  }) {
    final busy = task != null;
    final canApprove = permissions.canApproveDesign;
    final canSendBack = permissions.canEditJob;

    return CadFooter(
      // Only the approval's block is stated here. The rejection's gate is stated *on the field*
      // the moment it is hit, which is where the fix is (D-011 rule 2).
      blockedReason: canApprove ? null : permissions.blockReason(Capability.approveDesign),
      note: bundle.stageToClose == null
          ? bundle.advanceNote
          : 'Approving closes the ${bundle.stageToClose!.stage.label} stage and moves the job on.',
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                // Deliberately live with an empty comment. Pressing it is how the operator
                // learns the rule — see the class doc and D-011 rule 2.
                onPressed: busy || !canSendBack ? null : () => _requestRevisions(bundle),
                icon: task == CadTask.requestRevisions
                    ? const _ButtonSpinner()
                    : const Icon(Icons.replay_rounded, size: 18),
                label: const Text('Request Revisions'),
              ),
            ),
            const SizedBox(width: Spacing.sm + Spacing.xs),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy || !canApprove ? null : () => _approve(bundle),
                icon: task == CadTask.approve
                    ? const _ButtonSpinner()
                    : const Icon(Icons.check_rounded, size: 18),
                label: Text('Approve ${bundle.revision.version}'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _settledFooter(CadReviewBundle bundle) {
    return CadFooter(
      note: 'The design of record. Offer a new version to change it.',
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context.go(Paths.job(bundle.job.id)),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Open the job'),
              ),
            ),
            const SizedBox(width: Spacing.sm + Spacing.xs),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => unawaited(
                  RevisionUploadScreen.push(context, jobId: bundle.job.id),
                ),
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: const Text('Offer a new version'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // -------------------------------------------------------------- actions

  Future<void> _approve(CadReviewBundle bundle) async {
    final version = bundle.revision.version;
    final comment = _comment.text.trim();
    final openPins = bundle.openAnnotations.length;

    final confirmed = await confirmAction(
      context,
      title: 'Approve $version?',
      message: [
        'This locks $version so it cannot be changed, and records your name against it.',
        if (bundle.stageToClose != null)
          'The ${bundle.stageToClose!.stage.label} stage closes and the job moves on.'
        else
          bundle.advanceNote ?? '',
        if (openPins > 0)
          '$openPins annotation${openPins == 1 ? '' : 's'} on this version '
              '${openPins == 1 ? 'is' : 'are'} still open and will stay on the record as '
              'unaddressed.',
      ].where((line) => line.isNotEmpty).join('\n\n'),
      confirmLabel: 'Approve and lock $version',
      cancelLabel: 'Keep reviewing',
    );
    if (!confirmed || !mounted) return;

    try {
      await ref.read(cadActionsProvider.notifier).approve(
            bundle: bundle,
            comment: comment.isEmpty ? null : comment,
          );
      if (!mounted) return;
      _comment.clear();
      showDone(context, '$version is approved and locked.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  /// D-011 rule 2. The whole rule, in one place.
  Future<void> _requestRevisions(CadReviewBundle bundle) async {
    final comment = _comment.text.trim();

    if (comment.isEmpty) {
      // The mockup flashed an error ring and rewrote the placeholder for two seconds. Same
      // instinct, made durable: name the rule, focus the field, bring it on screen.
      setState(() => _commentError = CadReview.rejectionNeedsComment);
      _commentFocus.requestFocus();
      final box = _commentKey.currentContext;
      if (box != null) {
        unawaited(
          Scrollable.ensureVisible(
            box,
            duration: context.motion(Motion.normal),
            curve: context.motionCurve,
            alignment: 0.1,
          ),
        );
      }
      return;
    }

    final designer = bundle.designer?.fullName ?? 'the designer';
    final confirmed = await confirmAction(
      context,
      title: 'Send ${bundle.revision.version} back?',
      message: 'This records a revision request against ${bundle.revision.version} and puts the '
          'job back on $designer\'s queue. The version stays unlocked so the next one can '
          'supersede it.\n\n$comment',
      confirmLabel: 'Request revisions',
      cancelLabel: 'Keep reviewing',
    );
    if (!confirmed || !mounted) return;

    try {
      await ref
          .read(cadActionsProvider.notifier)
          .requestRevisions(bundle: bundle, comment: comment);
      if (!mounted) return;
      _comment.clear();
      showDone(context, 'Revisions requested. $designer has it back.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _dropPin(CadReviewBundle bundle, double xPct, double yPct) async {
    final body = await _askForPinNote(context);
    if (body == null || !mounted) {
      if (mounted) setState(() => _placingPin = false);
      return;
    }
    setState(() => _placingPin = false);

    try {
      await ref.read(cadActionsProvider.notifier).dropPin(
            revisionId: bundle.revision.id,
            xPct: xPct,
            yPct: yPct,
            body: body,
          );
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _resolvePin(CadAnnotation pin) async {
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
}

// ================================================================= pin sheet

/// The note that makes a pin a remark rather than a dot.
///
/// Here the button really is held shut while the field is empty, and that is the right call: the
/// fix is one tap away in the field the operator is already looking at, and
/// `ProductionRepository.addCadAnnotation` refuses an empty body anyway.
Future<String?> _askForPinNote(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: const _PinSheet(),
    ),
  );
}

final class _PinSheet extends StatefulWidget {
  const _PinSheet();

  @override
  State<_PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends State<_PinSheet> {
  final _body = TextEditingController();

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _body.text.trim();

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'What is wrong here?',
              style: context.text.headlineSmall?.copyWith(color: context.scheme.onSurface),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'The pin already says where. This says what.',
              style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.md),
            TextField(
              controller: _body,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Annotation',
                hintText: 'Halo stones read thin — take the melee to 1.5mm.',
              ),
            ),
            const SizedBox(height: Spacing.md),
            FilledButton(
              onPressed: text.isEmpty ? null : () => Navigator.of(context).pop(text),
              child: const Text('Drop the pin'),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================= chrome

/// The screen frame the loading and error states share with the real thing, so the header does
/// not appear only once the data lands.
final class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('CAD Review')),
        body: child,
      );
}

final class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
}
