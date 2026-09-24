/// DhanaOS design tokens — D-010.
///
/// Recovered from the two `DESIGN.md` files and the 46 Stitch exports. Two corrections were
/// applied rather than ported:
///
///  * The documents' prose hexes are **not** the shipped values. `#0A192F`, `#172A45` and
///    `#EAB308` appear nowhere in the 46 files. The tokens below are what actually shipped.
///  * Every export overrode the radius scale one step smaller than the spec declared, so
///    `rounded-full` rendered as a 12px square. The scale here is the intended one.
///
/// Every mockup declared `darkMode:"class"` yet contained zero `dark:` variants: light and dark
/// shipped as separate exports with complete standalone palettes bound to the same token names.
/// That means the markup was theme-agnostic by construction — one component set, two token sets.
library;

import 'package:flutter/material.dart';

/// Light palette — the product default. 38 of 46 screens, every dashboard and detail surface.
abstract final class LightTokens {
  static const surface = Color(0xFFF7F9FB);
  static const surfaceContainerLowest = Color(0xFFFFFFFF);
  static const surfaceContainerLow = Color(0xFFF2F4F6);
  static const surfaceContainer = Color(0xFFECEEF0);
  static const surfaceContainerHigh = Color(0xFFE6E8EA);
  static const surfaceContainerHighest = Color(0xFFE0E3E5);
  static const surfaceDim = Color(0xFFD8DADC);

  /// Pure black. The prose claimed a navy `#0F172A`; the shipped token is black.
  static const primary = Color(0xFF000000);
  static const onPrimary = Color(0xFFFFFFFF);

  /// Deep navy — where the prose's navy actually survives: the active nav item fill.
  static const primaryContainer = Color(0xFF131B2E);
  static const onPrimaryContainer = Color(0xFF7C839B);

  /// Vibrant indigo — priority badges, the active-stage pulse, focus rings.
  /// The prose quoted `#6366F1`; the shipped token is this.
  static const secondary = Color(0xFF4648D4);
  static const secondaryContainer = Color(0xFF6063EE);
  static const onSecondary = Color(0xFFFFFFFF);

  /// Gold — milestones, approvals, the critical path.
  static const gold = Color(0xFFF7BE1D);
  static const goldDim = Color(0xFFFFDF9A);
  static const onGold = Color(0xFF251A00);
  static const goldText = Color(0xFFA67E00);

  static const onSurface = Color(0xFF191C1E);
  static const onSurfaceVariant = Color(0xFF45464D);
  static const outline = Color(0xFF75777F);
  static const outlineVariant = Color(0xFFC5C6CF);

  static const error = Color(0xFFBA1A1A);
  static const onError = Color(0xFFFFFFFF);
  static const errorContainer = Color(0xFFFFDAD6);
  static const onErrorContainer = Color(0xFF410002);

  static const success = Color(0xFF2F6B46);
  static const successContainer = Color(0xFFDCEBE1);
}

/// Dark palette — the shop-floor and mobile theme. 8 screens, under the AuraForge mobile brand.
abstract final class DarkTokens {
  /// Deep midnight. The prose called this "Deep Midnight Blue #0A192F"; the shipped token
  /// is darker and cooler.
  static const surface = Color(0xFF041329);
  static const surfaceContainerLowest = Color(0xFF010E24);
  static const surfaceContainerLow = Color(0xFF0D1C32);

  /// The glass card fill. Always used at 70% opacity over a backdrop blur.
  static const surfaceContainer = Color(0xFF112036);
  static const surfaceContainerHigh = Color(0xFF1C2A41);
  static const surfaceContainerHighest = Color(0xFF27354C);
  static const surfaceBright = Color(0xFF2C3951);

  /// Metallic gold — primary actions, live-status dots, high-value indicators only.
  static const primary = Color(0xFFF2CA50);
  static const onPrimary = Color(0xFF3C2F00);
  static const primaryContainer = Color(0xFFD4AF37);
  static const onPrimaryContainer = Color(0xFF554300);

  /// Bright gold for progress fills. Its glow shadow is rgba(255,224,136,0.6).
  static const primaryFixed = Color(0xFFFFE088);
  static const onPrimaryFixed = Color(0xFF241A00);

  static const secondary = Color(0xFFB5C7EA);
  static const secondaryContainer = Color(0xFF354764);
  static const onSecondary = Color(0xFF1E314C);

  /// Electric mint — audio waveform bars, timers, success accents.
  static const tertiary = Color(0xFF45E6C3);
  static const tertiaryContainer = Color(0xFF06CAA8);
  static const tertiaryFixed = Color(0xFF5FFBD6);
  static const onTertiary = Color(0xFF00382D);

  /// Body text — a cool blue-white, never pure white.
  static const onSurface = Color(0xFFD6E3FF);

  /// Labels — a deliberately WARM sand against the cold ground. This single choice is what
  /// stops the dark theme reading as generic. Keep it.
  static const onSurfaceVariant = Color(0xFFD0C5AF);

  static const outline = Color(0xFF99907C);
  static const outlineVariant = Color(0xFF4D4635);

  static const error = Color(0xFFFFB4AB);
  static const onError = Color(0xFF690005);
  static const errorContainer = Color(0xFF93000A);
  static const onErrorContainer = Color(0xFFFFDAD6);

  static const success = Color(0xFF7FC79A);
  static const successContainer = Color(0xFF12301F);
}

/// Spacing scale. The exports used an 8px base with a 16px mobile margin.
abstract final class Spacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;

  /// The desktop sidebar. The mockups wrote `w-[sidebar-width]`, an arbitrary-value class that
  /// takes a CSS length and not a theme key — so the sidebar shipped with **no width at all**.
  static const sidebarWidth = 260.0;
  static const mobileMargin = 16.0;
  static const rowHeightSm = 32.0;
  static const rowHeight = 44.0;
}

/// Corner radii. Every export overrode this scale one step smaller than the spec, which made
/// `rounded-full` a 12px rounded square — so every chip and avatar rendered as a square.
abstract final class Radii {
  static const sm = 6.0;
  static const md = 10.0;
  static const lg = 16.0;
  static const xl = 24.0;

  /// A real pill, as the spec intended.
  static const full = 999.0;

  static const rSm = BorderRadius.all(Radius.circular(sm));
  static const rMd = BorderRadius.all(Radius.circular(md));
  static const rLg = BorderRadius.all(Radius.circular(lg));
  static const rXl = BorderRadius.all(Radius.circular(xl));
  static const rFull = BorderRadius.all(Radius.circular(full));
}

/// Motion. The exports used one easing curve throughout for segmented-control slides.
abstract final class Motion {
  static const curve = Cubic(0.2, 0.8, 0.2, 1.0);
  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 250);
  static const slow = Duration(milliseconds: 400);
}
