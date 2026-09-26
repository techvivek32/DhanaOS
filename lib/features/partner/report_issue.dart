/// The exception path, as a real record.
///
/// `caster_dashboard` drew "Report Issue" at exactly the same weight as "Mark Complete" — a 50/50
/// peer of the happy path — and put nothing behind it. That framing was right and the omission was
/// the problem: on a shop floor a shift ends one of two ways, and the one where something went
/// wrong is the one the workshop needs to hear about first.
///
/// What this screen writes is three things, in this order:
///
///  1. a `job_exceptions` row — the record, with the vendor attributed so
///     [JobException.isExternal] is true and whoever picks it up knows it needs a phone call;
///  2. `job_stages.state = 'blocked'` with the reason, which is what puts it on the manufacturer's
///     board rather than in somebody's inbox (a partner really can do this — `state` and
///     `blocked_reason` are inside the column grant at the end of `0009_rls.sql`);
///  3. an `action_items` row, so it surfaces in the Action Queue as "Patel Casting Works: Caster
///     delayed on DH-2026-01842 → Follow Up". In `manufacturer_dashboard` that line was hardcoded
///     and its button went nowhere.
///
/// The vendor cannot close what they opened, and that is deliberate rather than a gap: the
/// workshop decides when a delay is over, because they are the ones who have to tell the client.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/partner/partner_actions.dart';
import 'package:dhanaos/features/partner/partner_gateway.dart';
import 'package:dhanaos/features/partner/partner_surface.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// The five things that actually go wrong at a foundry, plus an escape hatch.
///
/// Presets are not a convenience: a typed headline is what the Action Queue prints, and
/// "asdf" typed at 7pm is a row nobody can triage. Each carries the severity it usually is, and
/// the operator can still change both.
enum IssuePreset {
  delayed(
    'Delayed',
    'Running behind the date it was promised back.',
    Icons.schedule_outlined,
    ActionSeverity.warning,
  ),
  castFailed(
    'Cast failed',
    'Porosity, an incomplete fill, or a flask that cracked.',
    Icons.local_fire_department_outlined,
    ActionSeverity.error,
  ),
  materialShort(
    'Material short',
    'Not enough metal to pour the tree as specified.',
    Icons.scale_outlined,
    ActionSeverity.error,
  ),
  specUnclear(
    'Spec does not add up',
    'The alloy, the temperatures or the model do not agree.',
    Icons.help_outline_rounded,
    ActionSeverity.warning,
  ),
  damage(
    'Damage in transit',
    'The wax or the piece arrived damaged.',
    Icons.broken_image_outlined,
    ActionSeverity.error,
  ),
  other(
    'Something else',
    'Write it in your own words.',
    Icons.edit_note_outlined,
    ActionSeverity.warning,
  );

  const IssuePreset(this.label, this.blurb, this.icon, this.severity);

  final String label;
  final String blurb;
  final IconData icon;

  /// What this kind of issue usually is. The operator can raise or lower it.
  final ActionSeverity severity;

  /// "Something else" owes the workshop its own headline; the rest prefill one.
  bool get needsOwnTitle => this == other;
}

/// How badly the job is affected. `action_severity` also declares `info` and `success`; neither is
/// an issue, so neither is offered here.
enum IssueImpact {
  slowing('Slowing us down', 'Work continues, but it will be late.', ActionSeverity.warning),
  stopped('Stopped', 'We cannot go any further until this is sorted.', ActionSeverity.error);

  const IssueImpact(this.label, this.blurb, this.severity);

  final String label;
  final String blurb;
  final ActionSeverity severity;

  static IssueImpact of(ActionSeverity severity) =>
      severity == ActionSeverity.error ? stopped : slowing;
}

final class ReportIssueScreen extends ConsumerStatefulWidget {
  const ReportIssueScreen({super.key, required this.jobId});

  final String jobId;

  /// Pushed rather than routed: reporting an issue is a task inside a job, and it belongs on the
  /// stack above the job it is about so backing out returns there.
  static Future<void> push(BuildContext context, {required String jobId}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ReportIssueScreen(jobId: jobId)),
      );

  @override
  ConsumerState<ReportIssueScreen> createState() => _ReportIssueScreenState();
}

class _ReportIssueScreenState extends ConsumerState<ReportIssueScreen> {
  IssuePreset? _preset;
  IssueImpact _impact = IssueImpact.slowing;

  /// On by default. An issue that does not show on the board is an issue nobody acts on — which
  /// is precisely what the mockup's button achieved by doing nothing at all.
  bool _blockStage = true;

  final TextEditingController _title = TextEditingController();
  final TextEditingController _detail = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _detail.dispose();
    super.dispose();
  }

  /// A report with no headline is a row nobody can triage, so submit stays shut until there is
  /// one — the same asymmetry D-011 rule 2 applies to a CAD rejection.
  String get _headline => _title.text.trim();

  bool get _ready => _headline.isNotEmpty;

  void _choose(IssuePreset preset) {
    setState(() {
      _preset = preset;
      _impact = IssueImpact.of(preset.severity);
      // Never overwrite something the caster has already typed.
      if (!preset.needsOwnTitle && _headline.isEmpty) {
        _title.text = preset.label;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(partnerJobBriefProvider(widget.jobId));

    return ShopFloorSurface(
      child: Scaffold(
        appBar: AppBar(title: const Text('Report an issue')),
        body: async.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(Spacing.md),
            child: LoadingSkeleton.list(count: 3),
          ),
          error: (error, _) => ErrorState(
            title: 'This job did not open',
            message: error is DhFailure
                ? error.message
                : 'DhanaOS could not read the job. Go back and open it from your queue.',
            detail: error is DhFailure ? error.detail : error.toString(),
            onRetry: () => ref.invalidate(partnerJobBriefProvider(widget.jobId)),
          ),
          data: _form,
        ),
      ),
    );
  }

  Widget _form(PartnerJobBrief brief) {
    final busy = ref.watch(partnerActionsProvider) != null;
    final sending = ref.watch(partnerActionsProvider) == PartnerTask.issue;
    final history = brief.exceptions;

    return ListView(
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xxl),
      children: [
        VendorJobLine(
          code: brief.job.displayCode,
          title: brief.job.displayTitle,
          priority: brief.job.priority,
          stage: brief.stage.stage,
        ),
        const SizedBox(height: Spacing.md),

        DhSectionCard(
          title: 'What happened',
          leading: const Icon(Icons.report_problem_outlined),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final preset in IssuePreset.values) ...[
                SelectableTile(
                  title: preset.label,
                  blurb: preset.blurb,
                  icon: preset.icon,
                  selected: _preset == preset,
                  enabled: !busy,
                  dense: true,
                  inGroup: true,
                  onTap: () => _choose(preset),
                ),
                const SizedBox(height: Spacing.sm),
              ],
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),

        DhSectionCard(
          title: 'In your words',
          leading: const Icon(Icons.edit_note_outlined),
          subtitle: 'The first line is what the workshop reads in their action queue.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                enabled: !busy,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 90,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Headline',
                  hintText: 'Flask cracked on the second pour',
                ),
              ),
              const SizedBox(height: Spacing.sm),
              TextField(
                controller: _detail,
                enabled: !busy,
                minLines: 4,
                maxLines: 8,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'What the workshop needs to know',
                  hintText: 'What you saw, what you have already tried, and what you need from '
                      'them to carry on.',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),

        DhSectionCard(
          title: 'How bad is it',
          leading: const Icon(Icons.speed_outlined),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DhSegmented<IssueImpact>(
                value: _impact,
                onChanged: (value) => setState(() => _impact = value),
                segments: [
                  // `enabled: false` is what shuts a segment — `DhSegmented` hands the tap a null
                  // callback rather than routing it through a no-op, so nothing can fire while the
                  // report is in flight.
                  for (final option in IssueImpact.values)
                    DhSegment(value: option, label: option.label, enabled: !busy),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                _impact.blurb,
                style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
              const SizedBox(height: Spacing.md),
              SwitchListTile.adaptive(
                value: _blockStage,
                onChanged: busy ? null : (value) => setState(() => _blockStage = value),
                contentPadding: EdgeInsets.zero,
                title: const Text('Flag the stage as blocked'),
                subtitle: Text(
                  _blockStage
                      ? 'The job shows as blocked on the workshop board until they clear it.'
                      : 'The job keeps running on the board. Use this for something they should '
                          'know about but that is not holding you up.',
                  style: context.text.bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),

        FilledButton.icon(
          onPressed: _ready && !busy ? () => unawaited(_submit(brief)) : null,
          icon: sending
              ? const ButtonSpinner()
              : const Icon(Icons.send_outlined, size: 18),
          label: const Text('Send it to the workshop'),
        ),
        if (!_ready) ...[
          const SizedBox(height: Spacing.sm),
          const GateNote(
            icon: Icons.edit_outlined,
            reason: 'Write a headline first. It is the line the workshop reads before they decide '
                'who picks this up.',
          ),
        ],

        if (history.isNotEmpty) ...[
          const SizedBox(height: Spacing.xl),
          SectionHeading(title: 'Already reported', count: history.length),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          for (final issue in history) ...[
            _HistoryCard(issue: issue),
            const SizedBox(height: Spacing.sm),
          ],
        ],
      ],
    );
  }

  Future<void> _submit(PartnerJobBrief brief) async {
    final agreed = await confirmAction(
      context,
      title: 'Send "$_headline" to the workshop?',
      message: _blockStage
          ? 'The job is flagged as blocked on their board and lands in their action queue. Only '
              'the workshop can close it again — you cannot take it back from here.'
          : 'This goes into their action queue as a note. The job keeps running on the board.',
      confirmLabel: 'Send it',
      cancelLabel: 'Keep editing',
    );
    if (!agreed || !mounted) return;

    try {
      await ref.read(partnerActionsProvider.notifier).reportIssue(
            brief: brief,
            title: _headline,
            detail: _detail.text.trim().isEmpty ? null : _detail.text.trim(),
            severity: _impact.severity,
            blockStage: _blockStage,
          );
      if (!mounted) return;
      showDone(context, 'Reported. The workshop has it in their action queue.');
      Navigator.of(context).pop();
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }
}

// ================================================================= history

/// One issue already on the record — open or closed.
///
/// A closed one carries its resolution, because `JobException.needsResolution` exists for exactly
/// this: a closed exception with no note leaves the audit trail unable to say what was done.
final class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.issue});

  final JobException issue;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final detail = issue.detail?.trim();
    final resolution = issue.resolution?.trim();

    return DhCard(
      tone: DhCardTone.inset,
      accent: issue.isOpen ? scheme.error : dh.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  issue.title,
                  style: context.text.titleMedium?.copyWith(color: scheme.onSurface),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              StatusChip(
                label: issue.isOpen ? 'Open' : 'Closed',
                tone: issue.isOpen ? ChipTone.danger : ChipTone.success,
                dense: true,
                dot: issue.isOpen,
              ),
            ],
          ),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              detail,
              style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: Spacing.sm),
          DataPair.timestamp(
            label: 'Reported',
            utc: issue.createdAt,
            emphasis: DataEmphasis.quiet,
          ),
          if (!issue.isOpen) ...[
            const SizedBox(height: Spacing.sm),
            GateNote(
              tone: GateTone.calm,
              icon: Icons.task_alt_rounded,
              reason: resolution == null || resolution.isEmpty
                  ? 'Closed by the workshop. No note was left saying what was done.'
                  : 'Closed by the workshop: $resolution',
            ),
          ],
        ],
      ),
    );
  }
}
