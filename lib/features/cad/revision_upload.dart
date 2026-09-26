/// Offering a new CAD version. NEW — no mockup had it.
///
/// The corpus reviewed CAD on one screen and downloaded an STL on another, and nothing in 46
/// files ever *produced* a revision: renders appeared out of nowhere, already numbered, already
/// annotated. This is the missing half of the loop, and three things it has to get right were
/// visible as absences in the source:
///
///  * **The change list is data, not prose.** `cad_revisions.spec_diff` holds
///    `{"halo melee": "1.5mm (from 1.2mm)"}`, so the reviewer reads a list and a later version
///    can be diffed against it. The mockup wrote that sentence into a paragraph where nothing
///    could act on it.
///  * **A version needs a render to be reviewable, and a mesh to be manufacturable.** Those are
///    two different gates, so only the first one blocks the offer, and the second is stated.
///  * **A version answering a revision request owes the reviewer a description.** That is the
///    mirror of D-011 rule 2: the rejection owed the designer a reason, so the answer owes the
///    reviewer an account of what moved.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/cad/cad_actions.dart';
import 'package:dhanaos/features/cad/cad_gateway.dart';
import 'package:dhanaos/features/cad/widgets/cad_widgets.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// What a mesh file is allowed to be. A caster opening a `.blend` has nothing to cast.
const _meshExtensions = <String>['stl', 'step', 'stp', '3dm', 'obj'];

/// One line of `spec_diff`, while the designer is typing it.
final class _DiffRow {
  _DiffRow({String field = '', String value = ''})
      : field = TextEditingController(text: field),
        value = TextEditingController(text: value);

  final TextEditingController field;
  final TextEditingController value;

  bool get isNamed => field.text.trim().isNotEmpty;

  void dispose() {
    field.dispose();
    value.dispose();
  }
}

final class RevisionUploadScreen extends ConsumerStatefulWidget {
  const RevisionUploadScreen({
    super.key,
    required this.jobId,
    this.answeringVersion,
    this.answeringComment,
  });

  final String jobId;

  /// 'v1.2' — the version that was sent back, when this offer answers a revision request.
  final String? answeringVersion;

  /// The reviewer's own words, kept on screen while the designer works so they do not have to
  /// hold them in their head across two screens.
  final String? answeringComment;

  bool get isAnswering => answeringComment != null;

  /// Returns the revision that was created, or null if the designer backed out.
  static Future<CadRevision?> push(
    BuildContext context, {
    required String jobId,
    String? answeringVersion,
    String? answeringComment,
  }) {
    return Navigator.of(context).push<CadRevision>(
      MaterialPageRoute<CadRevision>(
        builder: (_) => RevisionUploadScreen(
          jobId: jobId,
          answeringVersion: answeringVersion,
          answeringComment: answeringComment,
        ),
      ),
    );
  }

  @override
  ConsumerState<RevisionUploadScreen> createState() => _RevisionUploadScreenState();
}

class _RevisionUploadScreenState extends ConsumerState<RevisionUploadScreen> {
  final _version = TextEditingController();
  final _note = TextEditingController();
  final _renders = <CadUpload>[];
  final _diff = <_DiffRow>[];

  CadUpload? _mesh;
  int _step = 1;
  String? _progress;

  @override
  void initState() {
    super.initState();
    // Prefilling from the build method would mutate a controller mid-frame. This fires once the
    // job's current version is known, and never overwrites something the designer has typed.
    ref.listenManual<AsyncValue<RevisionContext>>(
      revisionContextProvider(widget.jobId),
      (previous, next) {
        final value = next.valueOrNull;
        if (value != null && _version.text.trim().isEmpty) {
          _version.text = value.suggestedVersion;
        }
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _version.dispose();
    _note.dispose();
    for (final row in _diff) {
      row.dispose();
    }
    super.dispose();
  }

  bool get _hasWork => _renders.isNotEmpty || _mesh != null || _note.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(revisionContextProvider(widget.jobId));

    return async.when(
      loading: () => const _Frame(
        child: Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: LoadingSkeleton.list(count: 3),
        ),
      ),
      error: (error, _) => _Frame(
        child: ErrorState(
          title: 'This job did not open',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read the job, so a new version cannot be numbered yet.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(revisionContextProvider(widget.jobId)),
        ),
      ),
      data: (job) => _step == 1 ? _stepFiles(job) : _stepChanges(job),
    );
  }

  // -------------------------------------------------------------- step 1

  Widget _stepFiles(RevisionContext job) {
    final busy = ref.watch(cadActionsProvider) == CadTask.offerRevision;

    return WizardScaffold(
      step: 1,
      totalSteps: 2,
      title: 'The new version',
      subtitle: job.isFirstOffer
          ? 'The first CAD on ${job.job.displayCode}.'
          : 'Supersedes ${job.latest!.version} on ${job.job.displayCode}.',
      trailing: StatusChip(
        label: job.job.displayCode,
        tone: ChipTone.neutral,
        dense: true,
        mono: true,
      ),
      onClose: busy ? null : _abandon,
      ctaLabel: 'Continue to what changed',
      ctaIcon: Icons.arrow_forward_rounded,
      ctaBlockedReason: WizardScaffold.firstUnmet({
        'Give the version a number. The shop reads it aloud across a bench, so "v1.3" beats '
            '"latest".': _version.text.trim().isNotEmpty,
        'Add at least one render. A version with no image cannot be reviewed, and the reviewer '
            'is the only person who can move this job on.': _renders.isNotEmpty,
      }),
      onCta: () => setState(() => _step = 2),
      children: [
        if (widget.isAnswering) ...[
          CadNote(
            tone: CadNoteTone.consequence,
            icon: Icons.replay_rounded,
            text: 'Answering the revision request on ${widget.answeringVersion ?? 'the last '
                'version'}:\n\n${widget.answeringComment}',
          ),
          const SizedBox(height: Spacing.md),
        ],
        DhSectionCard(
          title: 'Version number',
          subtitle: 'Unique on this job. A minor bump answers a revision request; a major one '
              'follows an approved version.',
          child: TextField(
            controller: _version,
            enabled: !busy,
            textCapitalization: TextCapitalization.none,
            style: AppTheme.mono(size: 15, weight: FontWeight.w700),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Version',
              hintText: job.suggestedVersion,
              prefixIcon: const Icon(Icons.numbers_rounded),
            ),
          ),
        ),
        const SizedBox(height: Spacing.md),
        DhSectionCard(
          title: 'Renders',
          subtitle: 'The first one is the image the review opens on and the one pins are dropped '
              'against. The rest sit under it as other views.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AttachmentGrid(
                items: [
                  for (final render in _renders)
                    AttachmentView(
                      id: render.localKey,
                      kind: render.kind,
                      filename: render.filename,
                      meta: 'Render · not uploaded yet',
                      thumbnail: FileImage(render.file),
                    ),
                ],
                addLabel: 'Add renders',
                onAdd: busy ? null : _pickRenders,
                onDelete: busy
                    ? null
                    : (view) => setState(
                          () => _renders.removeWhere((r) => r.localKey == view.id),
                        ),
              ),
              const SizedBox(height: Spacing.sm + Spacing.xs),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: busy ? null : _photograph,
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  label: const Text('Photograph the screen instead'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        DhSectionCard(
          title: 'Printable mesh',
          subtitle: 'STL, STEP, 3DM or OBJ. Optional now, required before the job reaches wax.',
          child: _mesh == null
              ? AddAttachmentTile(
                  onTap: busy ? _inert : _pickMesh,
                  label: 'Attach the mesh',
                  icon: Icons.hexagon_outlined,
                  height: 96,
                  hint: 'A caster cannot start from a render.',
                )
              : AttachmentTile.row(
                  item: AttachmentView(
                    id: _mesh!.localKey,
                    kind: _mesh!.kind,
                    filename: _mesh!.filename,
                    meta: 'STL / STEP · not uploaded yet',
                  ),
                  onRetake: busy ? null : _pickMesh,
                  onDelete: busy ? null : () => setState(() => _mesh = null),
                ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------- step 2

  Widget _stepChanges(RevisionContext job) {
    final task = ref.watch(cadActionsProvider);
    final busy = task == CadTask.offerRevision;
    final version = _version.text.trim();

    return WizardScaffold(
      step: 2,
      totalSteps: 2,
      title: 'What changed',
      subtitle: 'This is what the reviewer reads before they look at the render.',
      trailing: StatusChip(label: version, tone: ChipTone.accent, dense: true, mono: true),
      onBack: busy ? null : () => setState(() => _step = 1),
      onClose: busy ? null : _abandon,
      busy: busy,
      ctaLabel: 'Offer $version for review',
      ctaIcon: Icons.send_rounded,
      // The mirror of D-011 rule 2. A rejection owed the designer a reason; the answer owes the
      // reviewer an account of what moved. A first offer owes nothing — there is no claim to
      // answer yet.
      ctaBlockedReason: WizardScaffold.firstUnmet({
        'Say what you changed. You are answering a revision request, and the reviewer cannot '
            'tell from the render alone whether their note was acted on.':
            !widget.isAnswering || _note.text.trim().isNotEmpty,
      }),
      onCta: () => unawaited(_offer(job)),
      // While files are moving this is where the operator finds out how far they have got.
      footerNote: _progress ??
          'The job stays at ${job.rail.activeLifecycle?.label ?? 'CAD'} until a reviewer '
              'decides.',
      children: [
        if (widget.isAnswering) ...[
          CadNote(
            tone: CadNoteTone.info,
            icon: Icons.format_quote_rounded,
            text: widget.answeringComment!,
          ),
          const SizedBox(height: Spacing.md),
        ],
        DhSectionCard(
          title: 'Designer note',
          subtitle: 'Plain sentences. "Increased the halo melee from 1.2mm to 1.5mm for better '
              'presence" is the standard to beat.',
          child: TextField(
            controller: _note,
            enabled: !busy,
            minLines: 3,
            maxLines: 8,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'What you changed and why',
              hintText: 'Took the halo melee to 1.5mm, thickened the shank to 1.9mm at the '
                  'shoulders.',
            ),
          ),
        ),
        const SizedBox(height: Spacing.md),
        DhSectionCard(
          title: 'Change list',
          subtitle: 'Field by field, so the reviewer reads a list instead of hunting through a '
              'paragraph.',
          action: TextButton.icon(
            onPressed: busy ? null : () => setState(() => _diff.add(_DiffRow())),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add a line'),
          ),
          child: _diff.isEmpty
              ? const CadNote(
                  text: 'No change lines yet. They are optional, and they are also the only part '
                      'of a version a later revision can be compared against automatically.',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < _diff.length; i++) ...[
                      if (i > 0) const SizedBox(height: Spacing.sm),
                      _DiffRowField(
                        row: _diff[i],
                        enabled: !busy,
                        onRemove: () => setState(() => _diff.removeAt(i).dispose()),
                      ),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: Spacing.md),
        _summary(job, version),
      ],
    );
  }

  Widget _summary(RevisionContext job, String version) {
    return DhSectionCard(
      title: 'What is about to be offered',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DataPairGrid(
            children: [
              DataPair.mono(label: 'Version', value: version, emphasis: DataEmphasis.strong),
              DataPair.mono(label: 'Renders', value: '${_renders.length}'),
              DataPair(
                label: 'Mesh',
                value: _mesh == null ? 'Not attached' : _mesh!.filename,
                mono: _mesh != null,
              ),
              DataPair.mono(label: 'Supersedes', value: job.latest?.version ?? 'Nothing'),
            ],
          ),
          if (_mesh == null) ...[
            const SizedBox(height: Spacing.md),
            const CadNote(
              tone: CadNoteTone.risk,
              text: 'No mesh attached. The reviewer can still judge the design, but the caster '
                  'cannot start from a render — the STL has to land before the job reaches wax.',
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------- pickers

  /// [AddAttachmentTile] requires a callback. While an upload is in flight the tap is
  /// deliberately inert rather than the tile disappearing under the operator's thumb.
  void _inert() {}

  Future<void> _pickRenders() async {
    FilePickerResult? chosen;
    try {
      chosen = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.image,
      );
    } on Exception catch (error) {
      if (!mounted) return;
      showCadProblem(context, 'The file browser could not be opened. ($error)');
      return;
    }
    final result = chosen;
    if (result == null || !mounted) return;

    setState(() {
      for (final picked in result.files) {
        final path = picked.path;
        if (path == null) continue;
        if (_renders.any((r) => r.localKey == path)) continue;
        _renders.add(CadUpload.render(File(path), filename: picked.name));
      }
    });
  }

  Future<void> _photograph() async {
    XFile? picked;
    try {
      // 92 rather than the intake's 88: a reviewer judges 1.5mm melee off this image.
      picked = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 92);
    } on Exception catch (error) {
      if (!mounted) return;
      showCadProblem(
        context,
        'The camera could not be opened. Check that DhanaOS has camera permission. ($error)',
      );
      return;
    }
    final shot = picked;
    if (shot == null || !mounted) return;
    setState(() => _renders.add(CadUpload.render(File(shot.path), filename: shot.name)));
  }

  Future<void> _pickMesh() async {
    FilePickerResult? chosen;
    try {
      chosen = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _meshExtensions,
      );
    } on Exception catch (error) {
      if (!mounted) return;
      showCadProblem(context, 'The file browser could not be opened. ($error)');
      return;
    }
    final files = chosen?.files ?? const <PlatformFile>[];
    if (files.isEmpty || !mounted) return;
    final picked = files.first;
    final path = picked.path;
    if (path == null) return;

    setState(() => _mesh = CadUpload.model(File(path), filename: picked.name));
  }

  // -------------------------------------------------------------- commit

  Future<void> _offer(RevisionContext job) async {
    final version = _version.text.trim();
    final note = _note.text.trim();
    final diff = <String, String>{
      for (final row in _diff)
        if (row.isNamed) row.field.text.trim(): row.value.text.trim(),
    };

    try {
      final revision = await ref.read(cadActionsProvider.notifier).offerRevision(
            jobId: widget.jobId,
            version: version,
            renders: List<CadUpload>.unmodifiable(_renders),
            model: _mesh,
            designerNote: note.isEmpty ? null : note,
            specDiff: diff,
            onProgress: (progress) {
              if (mounted) setState(() => _progress = progress.label);
            },
          );
      if (!mounted) return;
      setState(() => _progress = null);
      showDone(context, '$version is offered for review.');
      Navigator.of(context).pop(revision);
    } on DhFailure catch (failure) {
      if (!mounted) return;
      setState(() => _progress = null);
      showFailure(context, failure);
    }
  }

  Future<void> _abandon() async {
    if (!_hasWork) {
      Navigator.of(context).pop();
      return;
    }
    final confirmed = await confirmAction(
      context,
      title: 'Leave without offering?',
      message: 'The files you picked have not been uploaded yet, so nothing is kept. The version '
          'number stays free for the next attempt.',
      confirmLabel: 'Leave and discard',
      cancelLabel: 'Keep working',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop();
  }
}

// ================================================================= pieces

final class _DiffRowField extends StatelessWidget {
  const _DiffRowField({required this.row, required this.enabled, required this.onRemove});

  final _DiffRow row;
  final bool enabled;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 4,
          child: TextField(
            controller: row.field,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: 'Field',
              hintText: 'Halo melee',
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: Spacing.sm),
        Expanded(
          flex: 5,
          child: TextField(
            controller: row.value,
            enabled: enabled,
            style: AppTheme.mono(size: 13),
            decoration: const InputDecoration(
              labelText: 'Changed to',
              hintText: '1.5mm (from 1.2mm)',
              isDense: true,
            ),
          ),
        ),
        IconButton(
          onPressed: enabled ? onRemove : null,
          tooltip: 'Remove this line',
          icon: const Icon(Icons.close_rounded, size: 18),
        ),
      ],
    );
  }
}

final class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('New CAD version')),
        body: child,
      );
}
