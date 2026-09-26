/// The pieces the five CAD surfaces share: the work-state chip, the version diff, the decision
/// record, the pin row, and the sticky footer.
///
/// They are here rather than repeated per screen because the corpus already showed what happens
/// otherwise — the same state wore three different colours across 46 files, and "In Production"
/// was a literal class list on one screen and a different literal on the next.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/cad/cad_gateway.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

// ================================================================= state chip

/// One vocabulary for "where is this CAD", used by the queue, the review header and the
/// designer's response screen.
final class CadStateChip extends StatelessWidget {
  const CadStateChip(this.state, {super.key, this.dense = false});

  final CadWorkState state;
  final bool dense;

  @override
  Widget build(BuildContext context) => StatusChip(
        label: state.label,
        tone: toneOf(state),
        icon: iconOf(state),
        dense: dense,
        // A version waiting on somebody else's decision is parked, and a parked state earns the
        // dot rather than a colour shout.
        dot: state == CadWorkState.awaitingReview,
        tooltip: state.blurb,
      );

  static ChipTone toneOf(CadWorkState state) => switch (state) {
        CadWorkState.unassigned => ChipTone.warning,
        CadWorkState.drawing => ChipTone.accent,
        CadWorkState.awaitingReview => ChipTone.neutral,
        // A rejection is a rejection. D-011 rule 2 exists because it owes the designer a reason,
        // not because it is a soft outcome.
        CadWorkState.revisionsRequested => ChipTone.danger,
        CadWorkState.approved => ChipTone.success,
      };

  static IconData iconOf(CadWorkState state) => switch (state) {
        CadWorkState.unassigned => Icons.person_add_alt_outlined,
        CadWorkState.drawing => Icons.draw_outlined,
        CadWorkState.awaitingReview => Icons.hourglass_empty_rounded,
        CadWorkState.revisionsRequested => Icons.replay_rounded,
        CadWorkState.approved => Icons.lock_outline_rounded,
      };
}

// ================================================================= notes

/// What a strip of prose is doing on the screen.
enum CadNoteTone {
  /// Context the operator did not ask for but needs.
  info,

  /// What pressing the button will do. Gold, the house milestone colour.
  consequence,

  /// Something that will bite later — a missing mesh, an expired link.
  risk,

  /// A rule that has been satisfied.
  good,
}

/// A bordered line of prose. Used for every "here is why" on these screens, so no screen invents
/// its own warning treatment.
final class CadNote extends StatelessWidget {
  const CadNote({
    super.key,
    required this.text,
    this.tone = CadNoteTone.info,
    this.icon,
    this.action,
  });

  final String text;
  final CadNoteTone tone;
  final IconData? icon;

  /// A single affordance on the right — "Add the mesh", "Refresh".
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    final (Color background, Color foreground, IconData glyph) = switch (tone) {
      CadNoteTone.info => (
          dh.surfaceContainerLow,
          scheme.onSurfaceVariant,
          Icons.info_outline_rounded,
        ),
      CadNoteTone.consequence => (
          dh.gold.withValues(alpha: 0.14),
          dh.goldText,
          Icons.bolt_outlined,
        ),
      CadNoteTone.risk => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          Icons.warning_amber_rounded,
        ),
      CadNoteTone.good => (dh.successContainer, dh.success, Icons.check_circle_outline_rounded),
    };

    return Container(
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      decoration: BoxDecoration(
        color: background,
        borderRadius: Radii.rMd,
        border: Border.all(color: dh.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? glyph, size: 16, color: foreground),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              text,
              style: context.text.bodySmall?.copyWith(color: foreground),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: Spacing.sm),
            action!,
          ],
        ],
      ),
    );
  }
}

// ================================================================= spec diff

/// `cad_revisions.spec_diff` as a table.
///
/// The mockup wrote this sentence into prose — "Increased the halo melee stones from 1.2mm to
/// 1.5mm" — where nothing could act on it, sort it or check it against the spec. Stored as
/// `{"halo": "0.45ct tw (from 0.3ct)"}` it is a list a reviewer can read down.
final class SpecDiffTable extends StatelessWidget {
  const SpecDiffTable({super.key, required this.diff, this.emptyNote});

  final Map<String, dynamic> diff;

  /// Shown instead of the table when nothing structured was recorded.
  final String? emptyNote;

  @override
  Widget build(BuildContext context) {
    if (diff.isEmpty) {
      return CadNote(
        text: emptyNote ??
            'No field-by-field change list was recorded for this version. The designer note is '
            'the only description of what moved.',
      );
    }

    final entries = diff.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final scheme = context.scheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const Divider(height: Spacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child: Text(
                  humanLabel(entries[i].key),
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                flex: 5,
                child: Text(
                  _diffText(entries[i].value),
                  textAlign: TextAlign.end,
                  // Convention 5: a dimension or a carat weight is data, so it is monospaced.
                  style: AppTheme.mono(size: 12.5, color: scheme.onSurface),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A diff value arrives as whatever JSON held — a string, a number, occasionally null. An empty
/// cell in a change list reads as "unchanged", which is the opposite of what a missing value
/// means, so null prints as an em dash.
String _diffText(Object? value) {
  if (value == null) return '—';
  final text = '$value'.trim();
  return text.isEmpty ? '—' : text;
}

/// `center_stone` / `centerStone` -> 'Center Stone'. Diff keys are written by whoever authored
/// the revision, so both shapes turn up.
String humanLabel(String key) {
  final spaced = key
      .replaceAll('_', ' ')
      .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .trim();
  if (spaced.isEmpty) return key;
  return [
    for (final word in spaced.split(RegExp(r'\s+')))
      if (word.isEmpty) word else word[0].toUpperCase() + word.substring(1),
  ].join(' ');
}

// ================================================================= decision record

/// One past decision on a revision, as the audit trail holds it.
final class DecisionTile extends StatelessWidget {
  const DecisionTile({
    super.key,
    required this.review,
    required this.reviewerName,
    this.version,
  });

  final CadReview review;

  /// D-008: a name that came off an `app_users` row, never a literal.
  final String reviewerName;

  /// 'v1.2' — set when the tile appears in a history list covering several versions.
  final String? version;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final comment = review.comment?.trim();

    return DhCard(
      tone: DhCardTone.inset,
      accent: review.approved ? context.dh.success : scheme.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusChip(
                label: review.approved ? 'Approved' : 'Revisions requested',
                tone: review.approved ? ChipTone.success : ChipTone.danger,
                icon: review.approved
                    ? Icons.check_rounded
                    : Icons.replay_rounded,
                dense: true,
              ),
              if (version != null) ...[
                const SizedBox(width: Spacing.sm),
                Text(
                  version!,
                  style: AppTheme.mono(
                    size: 12,
                    weight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              PersonAvatar(name: reviewerName, size: 26),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  reviewerName,
                  style: context.text.bodyMedium?.copyWith(color: scheme.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                localStamp(review.createdAt),
                style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          if (comment != null && comment.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              comment,
              style: context.text.bodyMedium?.copyWith(color: scheme.onSurface),
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= annotation row

/// One pin, off the render and in a list, with the tick that closes it.
final class AnnotationTile extends StatelessWidget {
  const AnnotationTile({
    super.key,
    required this.number,
    required this.pin,
    required this.authorName,
    this.selected = false,
    this.onTap,
    this.onResolve,
    this.busy = false,
  });

  final int number;
  final CadAnnotation pin;
  final String authorName;
  final bool selected;
  final VoidCallback? onTap;

  /// Null when the viewer cannot close pins — a reviewer reading their own remarks back, or a
  /// pin that is already resolved.
  final VoidCallback? onResolve;

  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return DhCard(
      tone: DhCardTone.inset,
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: pin.isResolved ? dh.successContainer : scheme.secondary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              '$number',
              style: AppTheme.mono(
                size: 11,
                weight: FontWeight.w700,
                color: pin.isResolved ? dh.success : scheme.onSecondary,
              ),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pin.body,
                  style: context.text.bodyMedium?.copyWith(color: scheme.onSurface),
                ),
                const SizedBox(height: 2),
                Text(
                  '$authorName · ${localStamp(pin.createdAt)}',
                  style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (pin.isResolved)
            Padding(
              padding: const EdgeInsets.only(left: Spacing.sm),
              child: Icon(Icons.check_circle_rounded, size: 18, color: dh.success),
            )
          else if (onResolve != null)
            TextButton(
              onPressed: busy ? null : onResolve,
              child: const Text('Addressed'),
            ),
        ],
      ),
    );
  }
}

// ================================================================= job identity

/// The line every CAD screen opens with: the code, what it is, and who it is for.
///
/// Takes strings rather than a `Job` so the same widget serves a `Job` and a `JobListItem` — the
/// queue reads the view, the review screen reads the row.
final class CadJobLine extends StatelessWidget {
  const CadJobLine({
    super.key,
    required this.code,
    required this.title,
    this.customerName,
    this.priority,
    this.trailing,
  });

  final String code;
  final String title;
  final String? customerName;
  final Priority? priority;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // D-001: the job code is an identifier an operator reads down a column.
                  Text(
                    code,
                    style: AppTheme.mono(
                      size: 12.5,
                      weight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (priority != null && priority != Priority.standard) ...[
                    const SizedBox(width: Spacing.sm),
                    PriorityChip(priority!, dense: true, showStandard: false),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                title,
                style: context.text.titleMedium?.copyWith(color: scheme.onSurface),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (customerName != null) ...[
                const SizedBox(height: 2),
                Text(
                  customerName!,
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: Spacing.sm),
          trailing!,
        ],
      ],
    );
  }
}

// ================================================================= footer

/// The sticky action bar the four full-screen CAD surfaces share.
///
/// [blockedReason] renders as a visible strip, never as a tooltip: a long-press hint is
/// undiscoverable on a shop-floor tablet, which is how the mockups ended up with dead controls
/// nobody could explain. What it does **not** do is disable [children] — each action decides its
/// own enabled state, because D-011 rule 2 needs one button held shut (`Approve`, on permission)
/// and one deliberately live so it can explain itself on press (`Request Revisions`, on an empty
/// comment).
final class CadFooter extends StatelessWidget {
  const CadFooter({
    super.key,
    required this.children,
    this.blockedReason,
    this.note,
    this.progress,
  });

  final List<Widget> children;
  final String? blockedReason;

  /// Small print under the buttons.
  final String? note;

  /// Set while a multi-file upload is in flight — 'Uploading 2 of 3 — cad_mesh_v2.png'.
  final String? progress;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: dh.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (progress != null) ...[
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        progress!,
                        style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.sm + Spacing.xs),
              ],
              if (blockedReason != null) ...[
                CadNote(text: blockedReason!, tone: CadNoteTone.risk),
                const SizedBox(height: Spacing.sm + Spacing.xs),
              ],
              ...children,
              if (note != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  note!,
                  textAlign: TextAlign.center,
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ================================================================= formatting

/// Convention 7: Postgres hands us UTC, the operator reads local time.
String localStamp(DateTime utc, {bool withTime = true}) =>
    (withTime ? _stampWithTime : _stampDateOnly).format(utc.toLocal());

final _stampWithTime = DateFormat('d MMM yyyy · HH:mm');
final _stampDateOnly = DateFormat('d MMM yyyy');

/// '4h' / '3d' — how long something has been waiting, in the rail's own shorthand.
String shortDuration(Duration d) {
  if (d.inDays >= 1) return '${d.inDays}d';
  if (d.inHours >= 1) return '${d.inHours}h';
  return '${d.inMinutes}m';
}

// ================================================================= feedback

/// A problem the platform caused rather than the server: a camera with no permission, a file
/// browser that would not open.
///
/// `showFailure` is for a [DhFailure] and prints Postgres's own operator-facing sentence
/// verbatim. This is for everything else, and it says what failed and what to check — never
/// "something went wrong".
void showCadProblem(BuildContext context, String message) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
        backgroundColor: scheme.errorContainer,
        duration: const Duration(seconds: 5),
      ),
    );
}
