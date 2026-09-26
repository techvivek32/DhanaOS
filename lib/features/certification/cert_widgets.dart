/// The certification-specific widgets: the six-node stepper and one audit-trail row.
///
/// The shop-floor primitives ([ShopNote], [ShopFooter], [ShopJobLine], [ShopSpinner]) are shared
/// with QC and live in `features/qc/qc_widgets.dart`. They are not copied here on purpose — a
/// second bordered warning strip is how the source corpus ended up rendering one state in three
/// different colours.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/features/certification/certification_gateway.dart';

/// The lab leg as six nodes, each drawn from a fact rather than from a position in a list.
///
/// The mockup's stepper was six hardcoded divs. Here a node is `done`, `active`, `blocked` or
/// `pending` because of `certificates.status`, and its timestamp and the name beside it come from
/// the `activity_events` row written when that transition actually happened. A node nothing
/// recorded shows no date, which is the honest rendering — the mockup stamped all six.
final class CertStatusStepper extends StatelessWidget {
  const CertStatusStepper({super.key, required this.nodes, this.expectedBack});

  final List<CertNode> nodes;

  /// The SLA, printed against whichever node is waiting on the lab. No mockup had this field, so
  /// nothing there could ever be chased.
  final DateTime? expectedBack;

  static final _stamp = DateFormat('d MMM yyyy · HH:mm');

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < nodes.length; i++)
          _Node(
            node: nodes[i],
            isLast: i == nodes.length - 1,
            stampOf: _stamp.format,
            expectedBack: expectedBack,
          ),
      ],
    );
  }
}

final class _Node extends StatelessWidget {
  const _Node({
    required this.node,
    required this.isLast,
    required this.stampOf,
    required this.expectedBack,
  });

  final CertNode node;
  final bool isLast;
  final String Function(DateTime) stampOf;
  final DateTime? expectedBack;

  static const _dotSize = 18.0;
  static const _gutter = 24.0;

  /// A calendar day, not an instant: an SLA is a date a lab is chased against.
  static final _dayFormat = DateFormat('d MMM yyyy');

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    final (Color fill, Color glyph, IconData? icon) = switch (node.state) {
      CertNodeState.done => (dh.stageCompleted, scheme.surface, Icons.check_rounded),
      CertNodeState.active => (dh.stageActive, scheme.onSecondaryContainer, null),
      CertNodeState.blocked => (scheme.error, scheme.onError, Icons.priority_high_rounded),
      CertNodeState.pending => (dh.stagePending, scheme.onSurfaceVariant, null),
    };

    // The connector leaving a reached node is drawn as travelled; the rest stay neutral.
    final lineColor = node.isReached ? dh.stageCompleted : dh.outlineVariant;

    final labelColor = switch (node.state) {
      CertNodeState.pending => scheme.onSurfaceVariant,
      CertNodeState.blocked => scheme.error,
      _ => scheme.onSurface,
    };

    final at = node.at;
    final actor = node.actor;
    final showSla = expectedBack != null &&
        node.isActive &&
        (node.step == CertStep.atLab ||
            node.step == CertStep.grading ||
            node.step == CertStep.sent);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _gutter,
            child: Column(
              children: [
                Container(
                  width: _dotSize,
                  height: _dotSize,
                  decoration: BoxDecoration(
                    color: fill,
                    shape: BoxShape.circle,
                    border: node.isPending
                        ? Border.all(color: dh.outlineVariant)
                        : null,
                  ),
                  child: icon == null
                      ? null
                      : Icon(icon, size: 11, color: glyph),
                ),
                if (!isLast) Expanded(child: Container(width: 2, color: lineColor)),
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          node.step.label,
                          style: context.text.titleMedium?.copyWith(
                            color: labelColor,
                            fontWeight:
                                node.isActive ? FontWeight.w700 : FontWeight.w600,
                          ),
                        ),
                      ),
                      if (at != null)
                        Text(
                          stampOf(at.toLocal()),
                          style: AppTheme.mono(
                            size: 10.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    node.step.blurb,
                    style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (actor != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      actor,
                      style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                  if (showSla) ...[
                    const SizedBox(height: Spacing.xs),
                    Text(
                      'Promised back ${_dayFormat.format(expectedBack!.toLocal())}',
                      style: AppTheme.mono(size: 11, color: dh.goldText),
                    ),
                  ],
                  if (node.note != null) ...[
                    const SizedBox(height: Spacing.sm),
                    Container(
                      padding: const EdgeInsets.all(Spacing.sm),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: Radii.rSm,
                      ),
                      child: Text(
                        node.note!,
                        style: context.text.bodySmall
                            ?.copyWith(color: scheme.onErrorContainer),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row of the certification audit trail.
///
/// `certification` titled its feed an "Immutable Audit Trail" over markup that could not have
/// been one. This reads `activity_events`, on which Postgres has revoked UPDATE and DELETE — so
/// the title is now true.
final class CertTrailTile extends StatelessWidget {
  const CertTrailTile({super.key, required this.event});

  final CertEvent event;

  static final _stamp = DateFormat('d MMM yyyy · HH:mm');

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final detail = event.detail?.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm + Spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(
              Icons.circle,
              size: 7,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.summary,
                  style: context.text.bodyMedium?.copyWith(color: scheme.onSurface),
                ),
                if (detail != null && detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  '${event.actorDisplay} · ${_stamp.format(event.createdAt.toLocal())}',
                  style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
