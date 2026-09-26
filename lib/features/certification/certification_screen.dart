/// Gem-lab certification. A rebuild of `certification`, which drew the right screen over nothing.
///
/// What the source declared and never wired, and is working here:
///
///  * **"Certification Required: No".** A toggle with no branch behind it. Answering No now skips
///    the `cert` stage *and* zeroes `delivery_schedules.cert_buffer_d`, so the promised date stops
///    reserving three days for a lab that will never see the piece. The two writes are one action
///    ([CertActions.setRequired]) and the screen says both consequences out loud before it runs.
///  * **The six-node stepper.** Six hardcoded divs there; here each node's state comes from
///    `certificates.status` and each timestamp from the `activity_events` row written when that
///    transition happened.
///  * **The "Immutable Audit Trail".** Titled over markup that could not have been one. It now
///    reads `activity_events`, a table with UPDATE and DELETE revoked in Postgres.
///  * **An SLA.** There was no expected-return field at all, so no lab could ever be chased.
///  * **The lab rejection path** (D-006). No mockup had one. A rejection needs a reason, blocks
///    the stage through a `job_exceptions` row so it shows on the board, and a resubmission is a
///    new leg rather than an edit of the refusal.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/certification/cert_widgets.dart';
import 'package:dhanaos/features/certification/certification_actions.dart';
import 'package:dhanaos/features/certification/certification_gateway.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/qc/qc_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// The labs an operator can choose. `CertLab.none` is deliberately absent: "no lab" is the Yes/No
/// question above, not a lab, and offering it twice is how the mockups ended up with a toggle and
/// a dropdown that could disagree.
const _selectableLabs = <CertLab>[
  CertLab.igi,
  CertLab.gia,
  CertLab.hrd,
  CertLab.ags,
  CertLab.other,
];

final class CertificationScreen extends ConsumerStatefulWidget {
  const CertificationScreen({super.key, required this.jobId});

  /// `jobs.id`. The route is `/certification/:jobId`.
  final String jobId;

  static Future<void> push(BuildContext context, String jobId) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => CertificationScreen(jobId: jobId)),
      );

  @override
  ConsumerState<CertificationScreen> createState() => _CertificationScreenState();
}

class _CertificationScreenState extends ConsumerState<CertificationScreen> {
  static final _dayFormat = DateFormat('d MMM yyyy');

  final _number = TextEditingController();

  bool? _requiredDraft;
  CertLab? _labDraft;
  String? _labPartnerDraft;
  DateTime? _expectedBackDraft;
  PickedFile? _pdf;

  @override
  void initState() {
    super.initState();
    _number.addListener(_onNumberChanged);
  }

  @override
  void dispose() {
    _number
      ..removeListener(_onNumberChanged)
      ..dispose();
    super.dispose();
  }

  void _onNumberChanged() => setState(() {});

  // -------------------------------------------------------------- draft resolution

  bool _required(CertBundle bundle) => _requiredDraft ?? bundle.isRequired;

  CertLab _lab(CertBundle bundle) {
    final drafted = _labDraft;
    if (drafted != null) return drafted;
    final current = bundle.lab;
    // A stored `none` means "not required", which the Yes/No control expresses. If the operator
    // flips back to Yes, offer the shop's default rather than an unselectable value.
    return current.skipsStage ? CertLab.igi : current;
  }

  String? _labPartner(CertBundle bundle) =>
      _labPartnerDraft ?? bundle.certificate?.labPartnerId;

  DateTime? _expectedBack(CertBundle bundle) =>
      _expectedBackDraft ?? bundle.certificate?.expectedBack;

  /// The declaration can only be edited while the piece is still in the building. Changing the
  /// lab after it has gone would be a record of something that did not happen.
  bool _declarationEditable(CertBundle bundle) =>
      !bundle.hasLeg || bundle.status == CertStatus.waiting;

  bool _declarationChanged(CertBundle bundle) {
    if (!bundle.hasLeg) return true;
    if (_required(bundle) != bundle.isRequired) return true;
    if (!_required(bundle)) return false;
    if (_lab(bundle) != bundle.lab) return true;
    if (_labPartner(bundle) != bundle.certificate?.labPartnerId) return true;
    return !_sameDay(_expectedBack(bundle), bundle.certificate?.expectedBack);
  }

  static bool _sameDay(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(certBundleProvider(widget.jobId));

    return async.when(
      loading: () => const _Frame(
        child: Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoadingSkeleton(height: 72),
              SizedBox(height: Spacing.md),
              LoadingSkeleton(height: 40, radius: Radii.rMd),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.lines(count: 6),
            ],
          ),
        ),
      ),
      error: (error, _) => _Frame(
        child: ErrorState(
          title: 'The certification leg did not open',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read the certificate. Check the connection and try again.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(certBundleProvider(widget.jobId)),
        ),
      ),
      data: _loaded,
    );
  }

  Widget _loaded(CertBundle bundle) {
    final permissions = ref.watch(permissionsProvider);
    final task = ref.watch(certActionsProvider);
    final busy = task != null;
    // The route is already fenced to AreaRoles.logistics by the router's RoleGate (D-008), so the
    // only thing left to check is that the session is a live internal account.
    final mayWrite = permissions.isInternal && (permissions.user?.isActive ?? false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Certification'),
        actions: [
          IconButton(
            onPressed: busy ? null : () => ref.invalidate(certBundleProvider(widget.jobId)),
            tooltip: 'Re-read this certificate',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(certBundleProvider(widget.jobId).future),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xl),
          children: [
            _header(bundle),
            const SizedBox(height: Spacing.md),
            if (bundle.rail.isSeeded) ...[
              JobStageRail.compact(nodes: _railNodes(bundle)),
              const SizedBox(height: Spacing.md),
            ],
            ..._banners(bundle),
            _declaration(bundle, busy: busy, mayWrite: mayWrite, task: task),
            if (_required(bundle) && bundle.hasLeg) ...[
              const SizedBox(height: Spacing.md),
              _stepper(bundle),
              if (_showCertificateBlock(bundle)) ...[
                const SizedBox(height: Spacing.md),
                _certificateBlock(bundle, busy: busy, mayWrite: mayWrite, task: task),
              ],
            ],
            const SizedBox(height: Spacing.md),
            _trail(bundle),
            if (bundle.history.length > 1) ...[
              const SizedBox(height: Spacing.md),
              _earlierLegs(bundle),
            ],
          ],
        ),
      ),
      bottomNavigationBar:
          _footer(bundle, task: task, mayWrite: mayWrite, permissions: permissions),
    );
  }

  List<StageNode> _railNodes(CertBundle bundle) => [
        for (final row in bundle.rail.stages)
          StageNode(
            stage: row.stage,
            state: row.state,
            detail: row.isActive ? row.dwellLabel : null,
            isLate: row.isLate,
            withPartner: row.isWithPartner,
          ),
      ];

  // -------------------------------------------------------------- header

  Widget _header(CertBundle bundle) {
    final dh = context.dh;
    final days = bundle.daysToReturn;

    return DhCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShopJobLine(
            code: bundle.job.displayCode,
            title: bundle.job.displayTitle,
            priority: bundle.job.priority,
            trailing: bundle.isRequired
                ? StatusChip.cert(bundle.status, dense: true)
                : const StatusChip(label: 'Not required', dense: true),
          ),
          const SizedBox(height: Spacing.md),
          DataPairGrid(
            children: [
              DataPair(
                label: 'Lab',
                value: bundle.isRequired ? bundle.labLabel : 'None',
                icon: Icons.workspace_premium_outlined,
              ),
              DataPair(
                label: 'Lab partner',
                value: bundle.labPartner?.name ?? 'Not chosen',
                icon: Icons.handshake_outlined,
              ),
              DataPair.mono(
                label: 'Certificate No.',
                value: bundle.certificate?.certNumber ?? '—',
                emphasis: DataEmphasis.strong,
              ),
              DataPair.mono(
                label: 'Expected back',
                value: bundle.certificate?.expectedBack == null
                    ? '—'
                    : _dayFormat.format(bundle.certificate!.expectedBack!.toLocal()),
                valueColor: bundle.isOverdue ? context.scheme.error : null,
              ),
              DataPair.mono(
                label: 'Lab window',
                value: days == null
                    ? '—'
                    : days < 0
                        ? '${-days} d late'
                        : '$days d left',
                valueColor: bundle.isOverdue ? context.scheme.error : dh.goldText,
              ),
              DataPair.mono(
                label: 'Delivery buffer',
                value: '${bundle.certBufferDays} d',
                // The figure the cross-screen dependency is about. Gold, because it is part of
                // what the customer was promised.
                valueColor: dh.goldText,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- banners

  List<Widget> _banners(CertBundle bundle) {
    final notes = <Widget>[];

    if (bundle.bufferDisagrees) {
      notes.add(
        ShopNote(
          text: 'The delivery plan still reserves ${bundle.certBufferDays} days for certification '
              'even though ${bundle.isRequired ? 'no lab is set' : 'this piece needs no lab'}. '
              'Save the declaration again to bring the two back into line.',
          tone: ShopNoteTone.risk,
        ),
      );
    }

    if (bundle.isOverdue) {
      final late = -(bundle.daysToReturn ?? 0);
      notes.add(
        ShopNote(
          text: '${bundle.labLabel} is $late day${late == 1 ? '' : 's'} past the date it promised. '
              'Chase it — the delivery plan is holding ${bundle.certBufferDays} days for this.',
          tone: ShopNoteTone.risk,
          icon: Icons.schedule_rounded,
          // A lab that has missed its date gives a new one on the phone. That has to land
          // somewhere, or the next person chases the date that already passed.
          action: TextButton(
            onPressed: () => unawaited(_reviseSla(bundle)),
            child: const Text('New date'),
          ),
        ),
      );
    }

    final exception = bundle.openException;
    if (exception != null) {
      notes.add(
        ShopNote(
          text: '${exception.title}${exception.detail == null ? '' : ' — ${exception.detail}'}',
          tone: ShopNoteTone.risk,
          icon: Icons.gpp_maybe_outlined,
        ),
      );
    }

    if (bundle.isStageSkipped) {
      notes.add(
        const ShopNote(
          text: 'The certification stage is marked skipped on this job. Nothing further is owed '
              'here.',
          tone: ShopNoteTone.good,
        ),
      );
    }

    if (!bundle.isRequired && !bundle.isStageSkipped && !bundle.isStageClosed) {
      notes.add(
        const ShopNote(
          text: 'This piece is set to ship without a gem-lab certificate. The certification stage '
              'will be skipped and the delivery plan reserves no days for a lab.',
          tone: ShopNoteTone.consequence,
        ),
      );
    }

    return [
      for (final note in notes) ...[note, const SizedBox(height: Spacing.md)],
    ];
  }

  // -------------------------------------------------------------- the conditional

  Widget _declaration(
    CertBundle bundle, {
    required bool busy,
    required bool mayWrite,
    required CertTask? task,
  }) {
    final editable = _declarationEditable(bundle) && mayWrite && !busy;
    final required = _required(bundle);
    final changed = _declarationChanged(bundle);

    return DhSectionCard(
      title: 'Certification required?',
      subtitle: _declarationEditable(bundle)
          ? 'The answer drives two things: whether the stage runs at all, and how many days the '
              'delivery plan holds back for the lab.'
          : 'The piece has already gone out, so the lab and the SLA are the record now.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_declarationEditable(bundle))
            DataPairGrid(
              children: [
                DataPair(label: 'Answer', value: required ? 'Required' : 'Not required'),
                DataPair(label: 'Lab', value: required ? bundle.labLabel : 'None'),
              ],
            )
          else ...[
            DhSegmented<bool>(
              segments: [
                DhSegment<bool>(
                  value: true,
                  label: 'Required',
                  icon: Icons.workspace_premium_outlined,
                  enabled: editable,
                ),
                DhSegment<bool>(
                  value: false,
                  label: 'Not required',
                  icon: Icons.block_rounded,
                  enabled: editable,
                  disabledReason: editable
                      ? null
                      : 'The declaration is fixed once the piece leaves the building.',
                ),
              ],
              value: required,
              accent: true,
              onChanged: (value) {
                if (!editable) return;
                setState(() => _requiredDraft = value);
              },
            ),
            if (required) ...[
              const SizedBox(height: Spacing.md),
              Text(
                'LAB',
                style: context.text.labelSmall
                    ?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
              const SizedBox(height: Spacing.sm),
              SelectableTileGroup<CertLab>(
                values: _selectableLabs,
                selected: _lab(bundle),
                dense: true,
                labelOf: (lab) => lab.label,
                blurbOf: (lab) => lab == CertLab.other
                    ? 'The name typed on the quality step of the job order is used'
                    : null,
                enabledOf: (_) => editable,
                onChanged: (lab) => setState(() => _labDraft = lab),
              ),
              const SizedBox(height: Spacing.md),
              _labPartnerPicker(bundle, editable: editable),
              const SizedBox(height: Spacing.md),
              _expectedBackRow(bundle, editable: editable),
            ] else ...[
              const SizedBox(height: Spacing.md),
              const ShopNote(
                text: 'Saving "Not required" writes two things: the certification stage is marked '
                    'to be skipped, and the delivery plan\'s certification buffer goes to zero. '
                    'Both are reversible by answering Required again.',
                tone: ShopNoteTone.consequence,
              ),
            ],
            const SizedBox(height: Spacing.md),
            FilledButton.icon(
              onPressed: !editable || !changed
                  ? null
                  : () => unawaited(_saveDeclaration(bundle)),
              icon: task == CertTask.declare
                  ? const ShopSpinner()
                  : const Icon(Icons.save_outlined, size: 18),
              label: Text(
                bundle.hasLeg ? 'Save the declaration' : 'Start the certification leg',
              ),
            ),
            if (!changed && bundle.hasLeg) ...[
              const SizedBox(height: Spacing.sm),
              Text(
                'Nothing to save — this is what is already on the job.',
                textAlign: TextAlign.center,
                style: context.text.bodySmall
                    ?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _labPartnerPicker(CertBundle bundle, {required bool editable}) {
    if (bundle.labs.isEmpty) {
      return const ShopNote(
        text: 'No gem lab is on the partner book yet. The lab can still be recorded above; add '
            'the partner in Partners so shipments and queues can be scoped to it.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'LAB PARTNER',
          style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
        ),
        const SizedBox(height: Spacing.sm),
        SelectableTileGroup<Partner>(
          values: bundle.labs,
          // Nothing highlighted until a partner is actually chosen. The mockups' pre-selected
          // first option is how a job ends up allocated to a vendor nobody picked.
          selected: bundle.labs.firstWhereOrNull((p) => p.id == _labPartner(bundle)),
          dense: true,
          labelOf: (partner) => partner.name,
          blurbOf: (partner) => partner.contactName,
          enabledOf: (_) => editable,
          onChanged: (partner) => setState(() => _labPartnerDraft = partner.id),
        ),
      ],
    );
  }

  /// The SLA the mockup had no field for, which is why nothing there could ever be chased.
  Widget _expectedBackRow(CertBundle bundle, {required bool editable}) {
    final due = _expectedBack(bundle);
    return DhCard(
      tone: DhCardTone.inset,
      child: Row(
        children: [
          Expanded(
            child: DataPair.mono(
              label: 'Expected back',
              value: due == null ? 'Not set' : _dayFormat.format(due.toLocal()),
              emphasis: DataEmphasis.strong,
            ),
          ),
          TextButton(
            onPressed: editable ? () => unawaited(_pickExpectedBack(bundle)) : null,
            child: Text(due == null ? 'Set the date' : 'Change'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- stepper

  Widget _stepper(CertBundle bundle) => DhSectionCard(
        title: 'Lab progress',
        subtitle: 'Every node below is a recorded event, not a step counter.',
        child: CertStatusStepper(
          nodes: bundle.nodes,
          expectedBack: bundle.certificate?.expectedBack,
        ),
      );

  // -------------------------------------------------------------- the certificate

  /// The number and the report can be entered from the moment the lab has the piece — a report
  /// sometimes arrives ahead of the piece coming back.
  bool _showCertificateBlock(CertBundle bundle) {
    if (bundle.isRejected) return false;
    return bundle.step.index >= CertStep.atLab.index;
  }

  Widget _certificateBlock(
    CertBundle bundle, {
    required bool busy,
    required bool mayWrite,
    required CertTask? task,
  }) {
    final cert = bundle.certificate;
    final existing = cert?.certNumber?.trim() ?? '';
    final typed = _number.text.trim();
    final pdf = _pdf;

    if (bundle.isComplete && typed.isEmpty && pdf == null) {
      return DhSectionCard(
        title: 'The certificate',
        subtitle: 'Number and report both on file.',
        action: StatusChip.code(existing, dense: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (bundle.pdf != null)
              AttachmentTile.row(
                item: AttachmentView(
                  id: bundle.pdf!.id,
                  kind: bundle.pdf!.kind,
                  filename: bundle.pdf!.filename,
                  meta: bundle.pdf!.metaLabel,
                ),
                onOpen: bundle.pdfUrl == null
                    ? null
                    : () => unawaited(_openPdf(bundle.pdf!, bundle.pdfUrl!)),
              ),
            const SizedBox(height: Spacing.md),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                // Putting the number back in the field is what switches this card into its
                // editable form — the listener rebuilds, so no explicit setState is needed.
                onPressed:
                    busy || !mayWrite ? null : () => _number.text = existing,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Correct the number or replace the report'),
              ),
            ),
          ],
        ),
      );
    }

    return DhSectionCard(
      title: 'The certificate',
      subtitle: 'Both halves together: a number with no report is a claim, and a report nobody '
          'indexed cannot be found again.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _number,
            enabled: mayWrite && !busy,
            keyboardType: TextInputType.number,
            style: AppTheme.mono(size: 15, color: context.scheme.onSurface),
            decoration: InputDecoration(
              labelText: 'Certificate number',
              hintText: 'e.g. 1234567890',
              helperText: existing.isEmpty
                  ? 'Copy it from the report exactly as printed.'
                  : 'On file: $existing',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: Spacing.md),
          if (pdf == null)
            AddAttachmentTile(
              onTap: () => unawaited(_choosePdf()),
              label: 'Attach the report',
              icon: Icons.picture_as_pdf_outlined,
              height: 96,
              hint: bundle.pdf == null
                  ? 'PDF or a photograph of the report'
                  : 'Replaces ${bundle.pdf!.filename}',
            )
          else
            AttachmentTile.row(
              item: AttachmentView(
                id: pdf.file.path,
                kind: AttachmentKind.certificatePdf,
                filename: pdf.filename,
                meta: 'Uploads with the number',
              ),
              onRetake: busy ? null : () => unawaited(_choosePdf()),
              onDelete: busy ? null : () => setState(() => _pdf = null),
            ),
          const SizedBox(height: Spacing.md),
          FilledButton.icon(
            onPressed: busy || !mayWrite || typed.isEmpty
                ? null
                : () => unawaited(_record(bundle)),
            icon: task == CertTask.record
                ? const ShopSpinner()
                : const Icon(Icons.verified_outlined, size: 18),
            label: const Text('Record the certificate'),
          ),
          if (typed.isEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              'Enter the number exactly as printed on the report. A blank one is refused.',
              textAlign: TextAlign.center,
              style: context.text.bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------- trail

  Widget _trail(CertBundle bundle) => DhSectionCard(
        title: 'Audit trail',
        subtitle: 'Append-only. Postgres has UPDATE and DELETE revoked on these rows, so nothing '
            'in this app can rewrite one.',
        child: bundle.events.isEmpty
            ? const EmptyState(
                compact: true,
                icon: Icons.history_rounded,
                title: 'Nothing recorded yet',
                message: 'Every certification decision writes a row here as it happens — who did '
                    'it, when, and what changed.',
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final event in bundle.events) CertTrailTile(event: event),
                ],
              ),
      );

  Widget _earlierLegs(CertBundle bundle) {
    final earlier = bundle.history.sublist(1);
    return DhSectionCard(
      title: 'Earlier legs',
      subtitle: 'A resubmission after a rejection is a new leg. The refusal it answers is kept.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final leg in earlier) ...[
            _LegSummary(leg: leg),
            const SizedBox(height: Spacing.sm),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------- footer

  Widget? _footer(
    CertBundle bundle, {
    required CertTask? task,
    required bool mayWrite,
    required Permissions permissions,
  }) {
    final busy = task != null;
    final blocked = mayWrite
        ? null
        : 'Certification is an internal action and needs an active account. '
            '${permissions.isSignedIn ? '' : 'Sign in again.'}'.trim();

    // Not required: the only thing left is closing the stage the job is standing on.
    if (!bundle.isRequired) {
      if (bundle.stageToClose == null) return null;
      return ShopFooter(
        blockedReason: blocked ?? bundle.closeBlockedReason,
        note: 'Closing it here does what `fn_complete_stage` would have done on the way in: the '
            'stage is finished business and the job moves to ${bundle.nextStageLabel}.',
        children: [
          FilledButton.icon(
            onPressed: busy || !mayWrite || !bundle.canCloseStage
                ? null
                : () => unawaited(_close(bundle)),
            icon: task == CertTask.close
                ? const ShopSpinner()
                : const Icon(Icons.skip_next_rounded, size: 18),
            label: Text('Skip certification · move to ${bundle.nextStageLabel}'),
          ),
        ],
      );
    }

    if (!bundle.hasLeg) return null;

    if (bundle.isRejected) {
      return ShopFooter(
        blockedReason: blocked,
        note: 'A resubmission opens a new leg. This rejection and its reason stay on the record.',
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
                  onPressed:
                      busy || !mayWrite ? null : () => unawaited(_resubmit(bundle)),
                  icon: task == CertTask.resubmit
                      ? const ShopSpinner()
                      : const Icon(Icons.replay_rounded, size: 18),
                  label: const Text('Resubmit to the lab'),
                ),
              ),
            ],
          ),
        ],
      );
    }

    if (bundle.status == CertStatus.waiting) {
      final due = _expectedBack(bundle);
      return ShopFooter(
        blockedReason: blocked,
        note: due == null
            ? 'You will be asked for the date the lab promised before it goes out.'
            : 'Promised back ${_dayFormat.format(due.toLocal())}.',
        children: [
          FilledButton.icon(
            onPressed: busy || !mayWrite ? null : () => unawaited(_send(bundle)),
            icon: task == CertTask.send
                ? const ShopSpinner()
                : const Icon(Icons.local_shipping_outlined, size: 18),
            label: Text('Send to ${bundle.labLabel}'),
          ),
        ],
      );
    }

    // Closing time: the certificate is in hand and the piece is back.
    if (bundle.canCloseStage) {
      final number = bundle.certificate?.certNumber?.trim();
      return ShopFooter(
        blockedReason: blocked,
        note: number == null || number.isEmpty
            ? 'Closing moves the job to ${bundle.nextStageLabel}.'
            : 'Certificate $number is on file. Closing moves the job to '
                '${bundle.nextStageLabel}.',
        children: [
          FilledButton.icon(
            onPressed: busy || !mayWrite ? null : () => unawaited(_close(bundle)),
            icon: task == CertTask.close
                ? const ShopSpinner()
                : const Icon(Icons.check_rounded, size: 18),
            label: Text('Close certification · move to ${bundle.nextStageLabel}'),
          ),
        ],
      );
    }

    // In flight with the lab: move it one step, or record the refusal.
    final next = bundle.nextStatuses.firstOrNull;
    final missing = bundle.outstanding;
    return ShopFooter(
      blockedReason: blocked,
      note: missing.isEmpty
          ? 'Each move writes a dated row on the audit trail above.'
          : 'Still to arrive: ${missing.join(' and ')}. Record it above when it lands; every '
              'move writes a dated row on the audit trail.',
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy || !mayWrite ? null : () => unawaited(_reject(bundle)),
                icon: task == CertTask.reject
                    ? const ShopSpinner()
                    : const Icon(Icons.gpp_bad_outlined, size: 18),
                label: const Text('Lab rejected it'),
              ),
            ),
            if (next != null) ...[
              const SizedBox(width: Spacing.sm + Spacing.xs),
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy || !mayWrite
                      ? null
                      : () => unawaited(_advance(bundle, next)),
                  icon: task == CertTask.advance
                      ? const ShopSpinner()
                      : const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: Text(_advanceLabel(next)),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  static String _advanceLabel(CertStatus status) => switch (status) {
        CertStatus.atLab => 'Lab received it',
        CertStatus.inProgress => 'Grading started',
        CertStatus.certified => 'Certified',
        CertStatus.returned => 'Back in the shop',
        _ => status.label,
      };

  // -------------------------------------------------------------- actions

  Future<void> _pickExpectedBack(CertBundle bundle) async {
    final today = DateTime.now();
    final seed = _expectedBack(bundle) ??
        today.add(Duration(days: bundle.certBufferDays > 0 ? bundle.certBufferDays : 7));
    final chosen = await showDatePicker(
      context: context,
      initialDate: seed.isBefore(today) ? today : seed,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      helpText: 'Date the lab promised',
    );
    if (chosen == null || !mounted) return;
    setState(() => _expectedBackDraft = chosen);
  }

  /// The cross-screen dependency, confirmed out loud before it runs.
  Future<void> _saveDeclaration(CertBundle bundle) async {
    final required = _required(bundle);

    if (!required) {
      final confirmed = await confirmAction(
        context,
        title: 'Ship ${bundle.job.displayCode} without a certificate?',
        message: 'Two things change. The certification stage will be skipped, so no lab work is '
            'expected on this job. And the delivery plan stops holding '
            '${bundle.certBufferDays} day${bundle.certBufferDays == 1 ? '' : 's'} back for the '
            'lab, which brings the promised date forward.\n\n'
            'Both are reversible by answering Required again.',
        confirmLabel: 'Skip certification',
        cancelLabel: 'Keep the lab',
      );
      if (!confirmed || !mounted) return;
    }

    try {
      await ref.read(certActionsProvider.notifier).setRequired(
            bundle: bundle,
            isRequired: required,
            lab: _lab(bundle),
            labPartnerId: _labPartner(bundle),
            expectedBack: _expectedBack(bundle),
          );
      if (!mounted) return;
      _clearDrafts();
      showDone(
        context,
        required
            ? 'Certification with ${_lab(bundle).label} is on the job.'
            : 'Certification skipped. The delivery buffer is now zero.',
      );
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _send(CertBundle bundle) async {
    var chosen = _expectedBack(bundle);
    if (chosen == null) {
      await _pickExpectedBack(bundle);
      if (!mounted) return;
      chosen = _expectedBackDraft;
    }
    final due = chosen;
    if (due == null) return;

    final confirmed = await confirmAction(
      context,
      title: 'Send ${bundle.job.displayCode} to ${bundle.labLabel}?',
      message: 'The piece leaves the building today and is promised back '
          '${_dayFormat.format(due.toLocal())}. That date is what the lab is chased against, and '
          'the delivery plan holds ${bundle.certBufferDays} day'
          '${bundle.certBufferDays == 1 ? '' : 's'} for it.',
      confirmLabel: 'Record it as sent',
      cancelLabel: 'Not yet',
    );
    if (!confirmed || !mounted) return;

    try {
      await ref.read(certActionsProvider.notifier).sendToLab(
            bundle: bundle,
            sentAt: DateTime.now(),
            expectedBack: due,
          );
      if (!mounted) return;
      _clearDrafts();
      showDone(context, 'Sent to ${bundle.labLabel}.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _reviseSla(CertBundle bundle) async {
    final today = DateTime.now();
    final chosen = await showDatePicker(
      context: context,
      initialDate: today.add(const Duration(days: 3)),
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      helpText: 'New date the lab promised',
    );
    if (chosen == null || !mounted) return;

    try {
      await ref
          .read(certActionsProvider.notifier)
          .reviseSla(bundle: bundle, expectedBack: chosen);
      if (!mounted) return;
      showDone(context, 'Now promised back ${_dayFormat.format(chosen)}.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _advance(CertBundle bundle, CertStatus status) async {
    try {
      await ref
          .read(certActionsProvider.notifier)
          .advance(bundle: bundle, status: status);
      if (!mounted) return;
      showDone(context, '${_advanceLabel(status)} — recorded.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _choosePdf() async {
    final source = await pickShopFileSource(
      context,
      title: 'Attach the lab report',
      blurb: 'A PDF from the lab, or a clear photograph of the printed report.',
    );
    if (source == null || !mounted) return;

    final PickedFile? picked;
    try {
      picked = await takeShopFile(source);
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
      return;
    }
    if (picked == null || !mounted) return;
    setState(() => _pdf = picked);
  }

  Future<void> _record(CertBundle bundle) async {
    final number = _number.text.trim();
    if (number.isEmpty) return;

    try {
      await ref.read(certActionsProvider.notifier).recordCertificate(
            bundle: bundle,
            certNumber: number,
            pdf: _pdf?.file,
            pdfFilename: _pdf?.filename,
          );
      if (!mounted) return;
      setState(() {
        _pdf = null;
        _number.clear();
      });
      showDone(context, 'Certificate $number recorded.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  /// D-006 — the path no mockup had.
  Future<void> _reject(CertBundle bundle) async {
    final note = await promptForText(
      context,
      title: '${bundle.labLabel} rejected the piece?',
      message: 'Write what the lab objected to, in their words where you have them. The bench '
          'cannot correct a fault nobody described, and this is what the certification stage '
          'shows on the board until it is resolved.',
      fieldLabel: 'What the lab said',
      hint: 'Girdle inscription illegible; report cannot be issued until it is re-laser-marked.',
      submitLabel: 'Record the rejection',
      destructive: true,
    );
    if (note == null || !mounted) return;

    final confirmed = await confirmAction(
      context,
      title: 'Block certification on ${bundle.job.displayCode}?',
      message: 'The leg is marked rejected and the certification stage is blocked, so the job '
          'stops moving until it is resolved. Resubmitting later opens a new leg.\n\n$note',
      confirmLabel: 'Record the rejection',
      cancelLabel: 'Go back',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    try {
      await ref.read(certActionsProvider.notifier).reject(bundle: bundle, note: note);
      if (!mounted) return;
      showDone(context, 'Rejection recorded. The certification stage is blocked.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _resubmit(CertBundle bundle) async {
    final fix = await promptForText(
      context,
      title: 'Resubmit to ${bundle.labLabel}?',
      message: 'Say what was done about the rejection. This closes the issue on the board, so it '
          'has to answer the question the rejection asked.',
      fieldLabel: 'What was corrected',
      hint: 'Girdle re-laser-marked at the bench and checked under 10x.',
      submitLabel: 'Continue',
    );
    if (fix == null || !mounted) return;

    await _pickExpectedBack(bundle);
    if (!mounted) return;
    final due = _expectedBackDraft;
    if (due == null) return;

    final confirmed = await confirmAction(
      context,
      title: 'Send it back to ${bundle.labLabel}?',
      message: 'A new certification leg is opened and marked sent today, promised back '
          '${_dayFormat.format(due.toLocal())}. The rejected leg stays on the record.\n\n$fix',
      confirmLabel: 'Resubmit',
      cancelLabel: 'Not yet',
    );
    if (!confirmed || !mounted) return;

    try {
      await ref.read(certActionsProvider.notifier).resubmit(
            bundle: bundle,
            sentAt: DateTime.now(),
            expectedBack: due,
            fixNote: fix,
          );
      if (!mounted) return;
      _clearDrafts();
      showDone(context, 'Resubmitted to ${bundle.labLabel}.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _close(CertBundle bundle) async {
    final number = bundle.certificate?.certNumber?.trim();
    final opening = bundle.isRequired
        ? number == null || number.isEmpty
            ? 'The certificate is on file.'
            : 'Certificate $number is on file.'
        : 'No lab is involved, so the stage closes without one.';

    final confirmed = await confirmAction(
      context,
      title: 'Close certification on ${bundle.job.displayCode}?',
      message: '$opening The job moves to ${bundle.nextStageLabel}. Stage history is '
          'append-only, so this cannot be undone.',
      confirmLabel: 'Close the stage',
      cancelLabel: 'Not yet',
    );
    if (!confirmed || !mounted) return;

    try {
      await ref.read(certActionsProvider.notifier).closeStage(bundle);
      if (!mounted) return;
      showDone(context, 'Certification closed. The job is at ${bundle.nextStageLabel}.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  /// A signed link, shown rather than opened.
  ///
  /// The link is deliberately short-lived — a public URL to a customer's certificate outlives the
  /// job and the relationship — so it is presented copyable, with its expiry stated, instead of
  /// being handed to an external viewer that would cache it.
  Future<void> _openPdf(Attachment file, String url) => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            file.filename,
            style: AppTheme.mono(size: 13, color: dialogContext.scheme.onSurface),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Copy this link into a browser to read the report. It stops working in thirty '
                'minutes, so it is safe to lose and not safe to forward.',
                style: dialogContext.text.bodySmall,
              ),
              const SizedBox(height: Spacing.md),
              SelectableText(
                url,
                style: AppTheme.mono(size: 11, color: dialogContext.scheme.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );

  /// Drop the local form state after a successful write, so the re-read is what the screen shows.
  void _clearDrafts() {
    setState(() {
      _requiredDraft = null;
      _labDraft = null;
      _labPartnerDraft = null;
      _expectedBackDraft = null;
    });
  }
}

// ================================================================= small pieces

final class _LegSummary extends StatelessWidget {
  const _LegSummary({required this.leg});

  final Certificate leg;

  static final _dayFormat = DateFormat('d MMM yyyy');

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final note = leg.rejectionNote?.trim();

    return DhCard(
      tone: DhCardTone.inset,
      accent: leg.isRejected ? scheme.error : context.dh.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusChip.cert(leg.status, dense: true),
              const Spacer(),
              Text(
                _dayFormat.format(leg.createdAt.toLocal()),
                style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            leg.displayLabel,
            style: AppTheme.mono(size: 13, color: scheme.onSurface),
          ),
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Text(note, style: context.text.bodySmall?.copyWith(color: scheme.onSurface)),
          ],
        ],
      ),
    );
  }
}

final class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Certification')),
        body: child,
      );
}
