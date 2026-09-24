/// D-009 — the requirement-code tag, e.g. `REQ-MAT-01`.
///
/// The mockups carried exactly five of these, all on one screen (`REQ-MAT-01` Base Metal,
/// `REQ-PUR-02` Alloy Purity, `REQ-GEM-03` Gemstone Inset, `REQ-FIN-04` Target Budget,
/// `REQ-TML-05` Delivery Target) — and they were the single best idea in the corpus, because they
/// give the shop floor, QC and the customer one shared citation for a spec line. QC's own
/// checklist helpers already read like requirement references ("Target: 4.8g Pt950. Allowable
/// variance: ±0.2g."). D-009 extends the scheme to every specification field.
///
/// The code shape is enforced in Postgres:
/// `constraint req_code_shape check (code ~ '^REQ-[A-Z]{3}-[0-9]{2}$')`. [ReqTag.codeShape]
/// mirrors it exactly so a malformed code is caught in the widget tree rather than at insert.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';

final class ReqTag extends StatelessWidget {
  const ReqTag({
    super.key,
    required this.code,
    this.critical = false,
    this.label,
    this.onTap,
  });

  /// Builds the code from its parts — `ReqTag.of(domain: 'MAT', seq: 1)` is `REQ-MAT-01`.
  factory ReqTag.of({
    Key? key,
    required String domain,
    required int seq,
    bool critical = false,
    String? label,
    VoidCallback? onTap,
  }) =>
      ReqTag(
        key: key,
        code: 'REQ-${domain.toUpperCase()}-${seq.toString().padLeft(2, '0')}',
        critical: critical,
        label: label,
        onTap: onTap,
      );

  /// The full code. Rendered verbatim and monospaced — it is an identifier, not prose.
  final String code;

  /// `requirements.is_critical`. A critical requirement is one QC will fail the piece over, so it
  /// wears the house gold instead of the neutral tint.
  final bool critical;

  /// The human name of the requirement — "Base Metal". Shown as the long-press tooltip, which is
  /// what makes a bare code usable by someone who has not memorised the domains.
  final String? label;

  /// Jumps to the requirement, wherever the feature wires it.
  final VoidCallback? onTap;

  /// The same regex as the `req_code_shape` CHECK in `0004_specifications.sql`.
  static final codeShape = RegExp(r'^REQ-[A-Z]{3}-[0-9]{2}$');

  static bool isValidCode(String code) => codeShape.hasMatch(code);

  @override
  Widget build(BuildContext context) {
    final dh = context.dh;
    final scheme = context.scheme;

    final fg = critical ? dh.goldText : scheme.onSurfaceVariant;
    final bg = critical ? dh.gold.withValues(alpha: 0.16) : dh.surfaceContainerHigh;
    final border = critical ? dh.gold.withValues(alpha: 0.5) : dh.outlineVariant;

    Widget tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: Radii.rSm,
        border: Border.all(color: border),
      ),
      child: Text(
        code,
        style: AppTheme.mono(size: 9.5, weight: FontWeight.w700, color: fg)
            .copyWith(letterSpacing: 0.4),
      ),
    );

    if (onTap != null) {
      tag = InkWell(onTap: onTap, borderRadius: Radii.rSm, child: tag);
    }

    final tooltip = label == null
        ? (critical ? 'Critical requirement $code' : code)
        : (critical ? '$code · $label — critical' : '$code · $label');

    return Tooltip(message: tooltip, child: tag);
  }
}

/// Pins a [ReqTag] to the top-trailing corner of any block, which is how the source screen laid
/// them out — the tag overhangs the field group it cites rather than taking a row of its own.
///
/// ```dart
/// ReqTagged(
///   tag: const ReqTag(code: 'REQ-MAT-01', label: 'Base Metal'),
///   child: DhSectionCard(title: 'Base Metal', child: …),
/// )
/// ```
final class ReqTagged extends StatelessWidget {
  const ReqTagged({
    super.key,
    required this.tag,
    required this.child,
    this.offset = const Offset(Spacing.sm + Spacing.xs, -10),
  });

  final ReqTag tag;
  final Widget child;

  /// Position of the tag relative to the block's top-right corner. `dx` insets from the right
  /// edge, `dy` from the top; the default straddles the top border the way the source screen drew
  /// it, so leave the parent about 10px of headroom. Positive `dy` moves the tag fully inside.
  final Offset offset;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(top: offset.dy, right: offset.dx, child: tag),
      ],
    );
  }
}
