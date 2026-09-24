/// The product's signature component: the horizontally scrolling 14-node lifecycle timeline
/// from `job_detail_dh_1048`.
///
/// D-002 locks the vocabulary — 14 stages, `inquiry` through `delivered` — and the rail is the
/// only place the whole vocabulary is visible at once. The dashboard's 8 operational counters are
/// a derived view over these nodes, never a second enum.
///
/// The source markup gave each node one of three structural states, and those three are what this
/// component is for:
///
///  * **completed** — filled in the primary ink, carrying a check.
///  * **active** — filled in the indigo/steel accent with a pulsing ring. The pulse was the only
///    animation in the entire 46-screen corpus that meant something: it is how an operator finds
///    "where is this job" in one glance down a list.
///  * **pending** — dimmed, outlined, showing its position number rather than a glyph.
///
/// Two states the source did not draw are added because D-005 and D-006 make them real:
/// `blocked` (the job has not left the stage, it is stuck in it) and `skipped` (certification is
/// skipped outright when `CertLab.none` was chosen). A skipped node is settled business, so the
/// connector past it reads as travelled.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/shared/widgets/reduced_motion.dart';

/// One node of the rail.
///
/// Deliberately a plain value type rather than the `JobStage` row: the rail is also drawn for a
/// draft that has no rows yet, for a partner brief that is only told the current stage, and in
/// tests. Mapping a row to a node is one line:
///
/// ```dart
/// StageRail(nodes: [
///   for (final s in rail.stages)
///     StageNode(stage: s.stage, state: s.state, detail: s.dwellLabel, isLate: s.isLate),
/// ])
/// ```
@immutable
final class StageNode {
  const StageNode({
    required this.stage,
    required this.state,
    this.detail,
    this.isLate = false,
    this.withPartner = false,
  });

  final LifecycleStage stage;
  final StageState state;

  /// The small mono line under the label — a dwell ("4h"), an initial ("JD"), a machine
  /// ("PR-02"). The mockups credited all three.
  final String? detail;

  /// Past its promised date and still open. Drawn as a gold ring, not as a colour change, so it
  /// does not fight the structural state.
  final bool isLate;

  /// Work that left the building. D-002 allows it only for casting and certification.
  final bool withPartner;

  bool get isCompleted => state == StageState.completed;
  bool get isActive => state == StageState.active;
  bool get isBlocked => state == StageState.blocked;
  bool get isSkipped => state == StageState.skipped;

  /// Settled either way. The connector leaving a settled node is drawn as travelled.
  bool get isSettled => isCompleted || isSkipped;

  /// All 14 nodes from a single known position — what a partner brief, a draft or a preview has.
  static List<StageNode> railFor({
    required LifecycleStage active,
    bool blocked = false,
    Set<LifecycleStage> skipped = const {},
    Map<LifecycleStage, String> details = const {},
  }) {
    return [
      for (final stage in LifecycleStage.values)
        StageNode(
          stage: stage,
          detail: details[stage],
          state: switch (stage) {
            _ when skipped.contains(stage) => StageState.skipped,
            _ when stage == active => blocked ? StageState.blocked : StageState.active,
            _ when stage.seq < active.seq => StageState.completed,
            _ => StageState.pending,
          },
        ),
    ];
  }
}

/// The full rail: scrolling nodes with labels. Use [StageRail.compact] inside a list row.
///
/// Note: `domain/models/job_stage.dart` also declares a `StageRail` — the *data* aggregate of 14
/// rows. Both names are correct in their own layer. A file that needs to write both type names
/// can reach this one through the [JobStageRail] alias.
final class StageRail extends StatefulWidget {
  const StageRail({
    super.key,
    required this.nodes,
    this.onTap,
    this.autoScrollToActive = true,
    this.padding = const EdgeInsets.symmetric(horizontal: Spacing.md),
  })  : compact = false,
        trailingLabel = false;

  /// Dots only, stretched to the available width — no scrolling, no labels. For a job card or a
  /// table row, where the rail answers "roughly how far along" and the detail screen answers the
  /// rest.
  const StageRail.compact({
    super.key,
    required this.nodes,
    this.onTap,
    this.trailingLabel = true,
    this.padding = EdgeInsets.zero,
  })  : compact = true,
        autoScrollToActive = false;

  final List<StageNode> nodes;
  final ValueChanged<StageNode>? onTap;
  final bool compact;

  /// Compact only: print the active stage name after the dots.
  final bool trailingLabel;

  /// Brings the active node into view on first paint. Without it a job at `dispatch` opens
  /// showing `inquiry`, which is the least useful part of the rail.
  final bool autoScrollToActive;

  final EdgeInsetsGeometry padding;

  @override
  State<StageRail> createState() => _StageRailState();
}

class _StageRailState extends State<StageRail> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  final _activeKey = GlobalKey();
  bool _scrolled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honour "remove animations" the moment the setting changes, not only at first build.
    if (MediaQuery.disableAnimationsOf(context)) {
      if (_pulse.isAnimating) _pulse.stop();
      _pulse.value = 0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
    _scheduleScroll();
  }

  @override
  void didUpdateWidget(StageRail old) {
    super.didUpdateWidget(old);
    final wasActive = old.nodes.indexWhere((n) => n.isActive || n.isBlocked);
    final isActive = widget.nodes.indexWhere((n) => n.isActive || n.isBlocked);
    if (wasActive != isActive) {
      _scrolled = false;
      _scheduleScroll();
    }
  }

  void _scheduleScroll() {
    if (widget.compact || !widget.autoScrollToActive || _scrolled) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _activeKey.currentContext;
      if (!mounted || target == null) return;
      _scrolled = true;
      Scrollable.ensureVisible(
        target,
        alignment: 0.5,
        duration: context.motion(Motion.slow),
        curve: context.motionCurve,
      );
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.nodes.isEmpty) return const SizedBox.shrink();
    return widget.compact ? _buildCompact(context) : _buildFull(context);
  }

  // ---------------------------------------------------------------- full rail

  static const _dotSize = 30.0;
  static const _ringBox = 46.0; // room for the active pulse, and the connector's datum line
  static const _nodeWidth = 70.0;
  static const _gap = 22.0;

  Widget _buildFull(BuildContext context) {
    final activeIndex = widget.nodes.indexWhere((n) => n.isActive || n.isBlocked);

    final children = <Widget>[];
    for (var i = 0; i < widget.nodes.length; i++) {
      if (i > 0) {
        children.add(_Connector(
          width: _gap,
          top: _ringBox / 2 - 1,
          travelled: widget.nodes[i - 1].isSettled,
        ));
      }
      children.add(_RailNode(
        key: i == activeIndex ? _activeKey : null,
        node: widget.nodes[i],
        pulse: _pulse,
        width: _nodeWidth,
        dotSize: _dotSize,
        ringBox: _ringBox,
        onTap: widget.onTap == null ? null : () => widget.onTap!(widget.nodes[i]),
        total: widget.nodes.length,
        position: i + 1,
      ));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: widget.padding,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  // ---------------------------------------------------------------- compact rail

  Widget _buildCompact(BuildContext context) {
    final active = widget.nodes.firstWhere(
      (n) => n.isActive || n.isBlocked,
      orElse: () => widget.nodes.last,
    );
    final settled = widget.nodes.where((n) => n.isSettled).length;

    final dots = <Widget>[];
    for (var i = 0; i < widget.nodes.length; i++) {
      if (i > 0) {
        dots.add(Expanded(
          child: _Connector(
            width: null,
            top: 0,
            travelled: widget.nodes[i - 1].isSettled,
          ),
        ));
      }
      dots.add(_CompactDot(node: widget.nodes[i], pulse: _pulse));
    }

    final row = Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: dots),
          ),
        ),
        if (widget.trailingLabel) ...[
          const SizedBox(width: Spacing.sm + Spacing.xs),
          Text(
            active.stage.label,
            style: context.text.labelSmall?.copyWith(color: context.scheme.onSurface),
          ),
          const SizedBox(width: Spacing.xs + 2),
          Text(
            '$settled/${widget.nodes.length}',
            style: AppTheme.mono(
              size: 10.5,
              color: context.scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );

    return Semantics(
      label: 'Stage ${active.stage.seq} of ${widget.nodes.length}, ${active.stage.label}. '
          '$settled settled.',
      excludeSemantics: true,
      child: Padding(padding: widget.padding, child: row),
    );
  }
}

/// The line between two nodes. Travelled segments take the primary ink; the rest stay at the
/// hairline colour so the eye reads progress before it reads any label.
final class _Connector extends StatelessWidget {
  const _Connector({required this.width, required this.top, required this.travelled});

  final double? width;
  final double top;
  final bool travelled;

  @override
  Widget build(BuildContext context) {
    final line = Container(
      height: 2,
      decoration: BoxDecoration(
        color: travelled ? context.dh.stageCompleted : context.dh.outlineVariant,
        borderRadius: Radii.rFull,
      ),
    );
    return SizedBox(
      width: width,
      child: top == 0 ? line : Padding(padding: EdgeInsets.only(top: top), child: line),
    );
  }
}

final class _RailNode extends StatelessWidget {
  const _RailNode({
    super.key,
    required this.node,
    required this.pulse,
    required this.width,
    required this.dotSize,
    required this.ringBox,
    required this.onTap,
    required this.position,
    required this.total,
  });

  final StageNode node;
  final Animation<double> pulse;
  final double width;
  final double dotSize;
  final double ringBox;
  final VoidCallback? onTap;
  final int position;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    final (Color fill, Color glyph, Color? border) = switch (node.state) {
      StageState.completed => (dh.stageCompleted, scheme.onPrimary, null),
      StageState.active => (dh.stageActive, scheme.onSecondaryContainer, null),
      StageState.blocked => (scheme.errorContainer, scheme.onErrorContainer, scheme.error),
      StageState.skipped => (Colors.transparent, dh.outlineVariant, dh.outlineVariant),
      StageState.pending => (
          dh.stagePending,
          scheme.onSurfaceVariant.withValues(alpha: 0.6),
          dh.outlineVariant,
        ),
    };

    final Widget inner = switch (node.state) {
      StageState.completed => Icon(Icons.check_rounded, size: dotSize * 0.55, color: glyph),
      StageState.blocked =>
        Icon(Icons.priority_high_rounded, size: dotSize * 0.55, color: glyph),
      StageState.skipped => Icon(Icons.remove_rounded, size: dotSize * 0.5, color: glyph),
      StageState.active => Container(
          width: dotSize * 0.32,
          height: dotSize * 0.32,
          decoration: BoxDecoration(color: glyph, shape: BoxShape.circle),
        ),
      StageState.pending => Text(
          '$position',
          style: AppTheme.mono(size: 11, weight: FontWeight.w600, color: glyph),
        ),
    };

    final dot = Container(
      width: dotSize,
      height: dotSize,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: border == null ? null : Border.all(color: border, width: 1.5),
      ),
      child: Center(child: inner),
    );

    final labelColor = switch (node.state) {
      StageState.active || StageState.blocked => scheme.onSurface,
      StageState.completed => scheme.onSurfaceVariant,
      // "pending-dim" is a real requirement, not a nicety: 14 labels at equal weight is noise.
      StageState.pending || StageState.skipped =>
        scheme.onSurfaceVariant.withValues(alpha: 0.55),
    };

    Widget cell = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: ringBox,
          width: width,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (node.isActive)
                _PulseRing(pulse: pulse, color: dh.stageActive, dotSize: dotSize),
              if (node.isLate)
                Container(
                  width: dotSize + 8,
                  height: dotSize + 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: dh.gold, width: 1.5),
                  ),
                ),
              dot,
            ],
          ),
        ),
        const SizedBox(height: Spacing.xs + 2),
        Text(
          node.stage.label,
          textAlign: TextAlign.center,
          maxLines: 2,
          style: context.text.labelSmall?.copyWith(
            color: labelColor,
            fontWeight: node.isActive ? FontWeight.w700 : FontWeight.w500,
            decoration: node.isSkipped ? TextDecoration.lineThrough : null,
          ),
        ),
        if (node.detail != null) ...[
          const SizedBox(height: 2),
          Text(
            node.detail!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.mono(
              size: 9.5,
              color: node.isLate ? context.dh.goldText : scheme.onSurfaceVariant,
            ),
          ),
        ],
        if (node.withPartner) ...[
          const SizedBox(height: 2),
          Icon(Icons.local_shipping_outlined, size: 12, color: scheme.onSurfaceVariant),
        ],
      ],
    );

    if (onTap != null) {
      cell = InkWell(
        onTap: onTap,
        borderRadius: Radii.rMd,
        child: cell,
      );
    }

    return SizedBox(
      width: width,
      child: Semantics(
        label: 'Stage $position of $total, ${node.stage.label}, ${node.state.label}'
            '${node.isLate ? ', overdue' : ''}',
        button: onTap != null,
        excludeSemantics: true,
        child: cell,
      ),
    );
  }
}

/// The pulse. An expanding, fading ring — the one animation in the source corpus that carried
/// information. It is suppressed entirely under reduced motion by the controller being held at 0,
/// which paints a single static ring at full alpha rather than nothing, so the active node still
/// stands out.
final class _PulseRing extends StatelessWidget {
  const _PulseRing({
    required this.pulse,
    required this.color,
    required this.dotSize,
    this.spread = 22,
  });

  final Animation<double> pulse;
  final Color color;
  final double dotSize;

  /// How far past the dot the ring travels. Must stay inside the parent box or the [Stack] will
  /// clip it — the compact rail passes a much smaller value than the full one.
  final double spread;

  @override
  Widget build(BuildContext context) {
    if (context.reduceMotion) {
      return Container(
        width: dotSize + spread * 0.4,
        height: dotSize + spread * 0.4,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 0.45), width: 2),
        ),
      );
    }
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        final t = Curves.easeOut.transform(pulse.value);
        final size = dotSize + spread * t;
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.30 * (1 - t)),
          ),
        );
      },
    );
  }
}

final class _CompactDot extends StatelessWidget {
  const _CompactDot({required this.node, required this.pulse});

  final StageNode node;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final dh = context.dh;
    final scheme = context.scheme;

    final (Color fill, Color? border, double size) = switch (node.state) {
      StageState.completed => (dh.stageCompleted, null, 8.0),
      StageState.active => (dh.stageActive, null, 11.0),
      StageState.blocked => (scheme.error, null, 11.0),
      StageState.skipped => (Colors.transparent, dh.outlineVariant, 8.0),
      StageState.pending => (dh.stagePending, dh.outlineVariant, 8.0),
    };

    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: border == null ? null : Border.all(color: border),
      ),
    );

    if (!node.isActive) return dot;
    return SizedBox(
      width: size + 8,
      height: size + 8,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _PulseRing(pulse: pulse, color: dh.stageActive, dotSize: size, spread: 8),
          dot,
        ],
      ),
    );
  }
}

/// Escape hatch for a library that must also name the `StageRail` data aggregate from
/// `domain/models/job_stage.dart`. Constructing through a typedef is legal Dart, so
/// `JobStageRail(nodes: …)` builds this widget with no import prefix gymnastics.
typedef JobStageRail = StageRail;
