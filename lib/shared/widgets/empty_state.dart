/// Empty, error and loading states — the three screens the mockups almost never drew.
///
/// Out of 46 exports there was one empty state and no error states at all: every list arrived
/// pre-populated with sample rows, every number was a literal, and nothing described what an
/// operator should do when the vault has no stones of that grade or when the insert was refused.
/// Those states are the majority of a real shop's day.
///
/// [EmptyState] and [ErrorState] centre themselves in whatever room they are given and scroll
/// instead of overflowing when that room is short — an empty state inside a 140px panel is a
/// normal thing to want, and a yellow-and-black overflow stripe is not an acceptable answer to it.
///
/// The copy rule for everything here (convention 8): say what happened and what to do next.
/// [ErrorState] additionally renders a server message **verbatim** — the four business rules are
/// enforced by Postgres functions whose `check_violation` messages are already written from the
/// operator's side ("Casting cannot complete without a casting photo."), and paraphrasing them in
/// Dart would let the two drift.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/shared/widgets/reduced_motion.dart';

/// Centres [content] in the available space, and lets it scroll when that space is shorter than
/// the content instead of overflowing. Under unbounded height it degrades to a plain [Center],
/// which is what it must do inside an outer scroll view.
Widget _centred(Widget content) => LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxHeight.isFinite) return Center(child: content);
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: content),
          ),
        );
      },
    );

final class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
    this.compact = false,
  });

  /// What is not here — "No jobs at casting".
  final String title;

  /// What to do about it — "Assign a job to a caster and it will appear here."
  final String message;

  final IconData icon;

  /// The action that fills the emptiness. Label it with the verb, not "OK".
  final String? actionLabel;
  final VoidCallback? onAction;

  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// Inside a card or a small panel rather than a whole screen.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return _centred(
      Padding(
        padding: EdgeInsets.all(compact ? Spacing.md : Spacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: compact ? 44 : 60,
                height: compact ? 44 : 60,
                decoration: BoxDecoration(
                  color: dh.surfaceContainerHigh,
                  borderRadius: Radii.rLg,
                ),
                child: Center(
                  child: Icon(
                    icon,
                    size: compact ? 22 : 28,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              SizedBox(height: compact ? Spacing.sm + Spacing.xs : Spacing.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: (compact ? context.text.titleMedium : context.text.headlineSmall)
                    ?.copyWith(color: scheme.onSurface),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (actionLabel != null && onAction != null) ...[
                SizedBox(height: compact ? Spacing.md : Spacing.lg),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
              if (secondaryLabel != null && onSecondary != null) ...[
                const SizedBox(height: Spacing.sm),
                TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A failure, with the server's own words kept intact.
final class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.title,
    required this.message,
    this.detail,
    this.onRetry,
    this.retryLabel = 'Try again',
    this.onSecondary,
    this.secondaryLabel,
    this.compact = false,
    this.icon = Icons.error_outline_rounded,
  });

  /// The shortest true statement — "Could not move the job to Casting".
  final String title;

  /// What to do. If the server explained itself, this is that explanation verbatim.
  final String message;

  /// Technical detail for a bug report — the PostgREST code, the request id. Collapsed by
  /// default; an operator should not have to read it, and support should not have to guess it.
  final String? detail;

  final VoidCallback? onRetry;
  final String retryLabel;
  final VoidCallback? onSecondary;
  final String? secondaryLabel;
  final bool compact;
  final IconData icon;

  /// A rule refused by Postgres. `check_violation` messages from `fn_complete_stage` and friends
  /// are already operator-facing, so they are shown as the message, not buried in [detail].
  factory ErrorState.ruleRefused({
    Key? key,
    required String serverMessage,
    String title = 'The shop floor rule refused this',
    VoidCallback? onRetry,
    String? detail,
  }) =>
      ErrorState(
        key: key,
        title: title,
        message: serverMessage,
        detail: detail,
        onRetry: onRetry,
        icon: Icons.gpp_maybe_outlined,
      );

  /// No route to Supabase. Distinct from a refusal: nothing was attempted, so retrying is the
  /// whole fix.
  factory ErrorState.offline({Key? key, VoidCallback? onRetry}) => ErrorState(
        key: key,
        title: 'No connection',
        message: 'DhanaOS could not reach the server. Check the shop Wi-Fi and try again — '
            'nothing you entered has been lost.',
        icon: Icons.wifi_off_rounded,
        onRetry: onRetry,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;

    return _centred(
      Padding(
        padding: EdgeInsets.all(compact ? Spacing.md : Spacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: compact ? 44 : 56,
                height: compact ? 44 : 56,
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: Radii.rLg,
                ),
                child: Center(
                  child: Icon(
                    icon,
                    size: compact ? 22 : 28,
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
              SizedBox(height: compact ? Spacing.sm + Spacing.xs : Spacing.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: (compact ? context.text.titleMedium : context.text.headlineSmall)
                    ?.copyWith(color: scheme.onSurface),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (detail != null) ...[
                const SizedBox(height: Spacing.md),
                _DetailDisclosure(detail: detail!),
              ],
              if (onRetry != null) ...[
                SizedBox(height: compact ? Spacing.md : Spacing.lg),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(retryLabel),
                ),
              ],
              if (secondaryLabel != null && onSecondary != null) ...[
                const SizedBox(height: Spacing.sm),
                TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

final class _DetailDisclosure extends StatefulWidget {
  const _DetailDisclosure({required this.detail});

  final String detail;

  @override
  State<_DetailDisclosure> createState() => _DetailDisclosureState();
}

class _DetailDisclosureState extends State<_DetailDisclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Column(
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _open = !_open),
          icon: Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
          label: Text(_open ? 'Hide detail' : 'Show detail'),
        ),
        AnimatedSize(
          duration: context.motion(Motion.fast),
          curve: context.motionCurve,
          child: _open
              ? Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
                  decoration: BoxDecoration(
                    color: context.dh.surfaceContainerLow,
                    borderRadius: Radii.rSm,
                    border: Border.all(color: context.dh.outlineVariant),
                  ),
                  child: SelectableText(
                    widget.detail,
                    style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// Shimmering placeholders. The shape of the skeleton has to match the shape of the content it
/// replaces, otherwise the screen jumps when data lands — so the named constructors mirror the
/// real components rather than offering generic grey bars.
final class LoadingSkeleton extends StatelessWidget {
  const LoadingSkeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = Radii.rSm,
  })  : _lines = 0,
        _kind = _SkeletonKind.box;

  /// A stack of text lines, the last one short, which is what a paragraph looks like.
  const LoadingSkeleton.lines({super.key, int count = 3})
      : width = null,
        height = 12,
        radius = Radii.rSm,
        _lines = count,
        _kind = _SkeletonKind.lines;

  /// One `DhCard`-shaped block: a title line, two body lines, a footer chip row.
  const LoadingSkeleton.card({super.key})
      : width = null,
        height = 12,
        radius = Radii.rLg,
        _lines = 0,
        _kind = _SkeletonKind.card;

  /// A column of card skeletons — a job list, a queue, an activity feed.
  const LoadingSkeleton.list({super.key, int count = 3})
      : width = null,
        height = 12,
        radius = Radii.rLg,
        _lines = count,
        _kind = _SkeletonKind.list;

  final double? width;
  final double height;
  final BorderRadius radius;
  final int _lines;
  final _SkeletonKind _kind;

  @override
  Widget build(BuildContext context) {
    return switch (_kind) {
      _SkeletonKind.box => _Shimmer(
          child: _Block(width: width, height: height, radius: radius),
        ),
      _SkeletonKind.lines => _Shimmer(child: _lineStack(_lines)),
      _SkeletonKind.card => _Shimmer(child: _card(context)),
      // A placeholder should run off the bottom of a short screen, not overflow it: in a bounded
      // slot the column is laid out at full height and clipped; in a scroll view it keeps its
      // own height.
      _SkeletonKind.list => _Shimmer(
          child: ClipRect(
            child: OverflowBox(
              fit: OverflowBoxFit.deferToChild,
              alignment: Alignment.topCenter,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < _lines; i++) ...[
                    if (i > 0) const SizedBox(height: Spacing.sm + Spacing.xs),
                    _card(context),
                  ],
                ],
              ),
            ),
          ),
        ),
    };
  }

  static Widget _lineStack(int count) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(height: Spacing.sm),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: i == count - 1 ? 0.55 : 1,
              child: const _Block(height: 12, radius: Radii.rSm),
            ),
          ],
        ],
      );

  static Widget _card(BuildContext context) => Container(
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: context.dh.surfaceContainerLowest,
          borderRadius: Radii.rLg,
          border: Border.all(color: context.dh.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                _Block(width: 96, height: 12, radius: Radii.rSm),
                Spacer(),
                _Block(width: 58, height: 18, radius: Radii.rFull),
              ],
            ),
            const SizedBox(height: Spacing.md),
            _lineStack(2),
            const SizedBox(height: Spacing.md),
            const Row(
              children: [
                _Block(width: 70, height: 10, radius: Radii.rSm),
                SizedBox(width: Spacing.md),
                _Block(width: 44, height: 10, radius: Radii.rSm),
              ],
            ),
          ],
        ),
      );
}

enum _SkeletonKind { box, lines, card, list }

final class _Block extends StatelessWidget {
  const _Block({this.width, this.height = 14, this.radius = Radii.rSm});

  final double? width;
  final double height;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: context.dh.surfaceContainerHigh, borderRadius: radius),
      );
}

/// Sweeps a highlight across whatever it wraps. Under reduced motion it paints the blocks flat
/// and runs no controller at all — a permanently shimmering screen is exactly what that setting
/// exists to stop.
final class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});

  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      if (_c.isAnimating) _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (context.reduceMotion) return widget.child;

    final highlight = context.dh.surfaceContainerHighest;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Colors.transparent,
            highlight.withValues(alpha: 0.75),
            Colors.transparent,
          ],
          stops: const [0.0, 0.5, 1.0],
          transform: _SlideGradient(_c.value * 2 - 1),
        ).createShader(bounds),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// Slides the gradient across the masked area, `-1` fully left to `1` fully right.
final class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.t);

  final double t;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * t, 0, 0);
}
