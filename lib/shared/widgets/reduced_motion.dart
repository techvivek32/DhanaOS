/// Accessibility gate for every animation in the design system.
///
/// Android's "Remove animations" setting and iOS's "Reduce Motion" both surface through
/// `MediaQueryData.disableAnimations`. The shop floor is exactly the place where an operator
/// may have turned motion off, so every animated component here routes its duration through
/// [ReducedMotionX.motion] rather than reading a [Motion] constant directly.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/tokens.dart';

extension ReducedMotionX on BuildContext {
  /// True when the platform asks us not to animate.
  bool get reduceMotion => MediaQuery.disableAnimationsOf(this);

  /// Collapses a duration to zero when motion is disabled. An implicit animation with a zero
  /// duration still settles on the correct final frame, so callers need no second code path.
  Duration motion(Duration d) => reduceMotion ? Duration.zero : d;

  /// The house easing curve, flattened when motion is disabled.
  Curve get motionCurve => reduceMotion ? Curves.linear : Motion.curve;
}
