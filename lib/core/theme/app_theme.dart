/// D-010 — one component set, two token sets.
///
/// The exports proved this is the right shape: every file declared `darkMode:"class"` and
/// contained zero `dark:` variants, because light and dark were complete standalone palettes
/// bound to the same token names. Widgets read `Theme.of(context)`; nothing hardcodes a colour.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// Colours the Material scheme has no slot for, reached via `context.dh`.
@immutable
class DhColors extends ThemeExtension<DhColors> {
  const DhColors({
    required this.gold,
    required this.onGold,
    required this.goldText,
    required this.success,
    required this.successContainer,
    required this.surfaceContainerLowest,
    required this.surfaceContainerLow,
    required this.surfaceContainerHigh,
    required this.surfaceContainerHighest,
    required this.outlineVariant,
    required this.stageCompleted,
    required this.stageActive,
    required this.stagePending,
  });

  /// Milestones, approvals, the critical path. In the dark theme this is also `primary`.
  final Color gold;
  final Color onGold;
  final Color goldText;
  final Color success;
  final Color successContainer;
  final Color surfaceContainerLowest;
  final Color surfaceContainerLow;
  final Color surfaceContainerHigh;
  final Color surfaceContainerHighest;
  final Color outlineVariant;

  /// The three structural states of a timeline node, straight from `job_detail_dh_1048`.
  final Color stageCompleted;
  final Color stageActive;
  final Color stagePending;

  static const light = DhColors(
    gold: LightTokens.gold,
    onGold: LightTokens.onGold,
    goldText: LightTokens.goldText,
    success: LightTokens.success,
    successContainer: LightTokens.successContainer,
    surfaceContainerLowest: LightTokens.surfaceContainerLowest,
    surfaceContainerLow: LightTokens.surfaceContainerLow,
    surfaceContainerHigh: LightTokens.surfaceContainerHigh,
    surfaceContainerHighest: LightTokens.surfaceContainerHighest,
    outlineVariant: LightTokens.outlineVariant,
    stageCompleted: LightTokens.primary,
    stageActive: LightTokens.secondaryContainer,
    stagePending: LightTokens.surfaceContainerHigh,
  );

  static const dark = DhColors(
    gold: DarkTokens.primary,
    onGold: DarkTokens.onPrimary,
    goldText: DarkTokens.primaryFixed,
    success: DarkTokens.success,
    successContainer: DarkTokens.successContainer,
    surfaceContainerLowest: DarkTokens.surfaceContainerLowest,
    surfaceContainerLow: DarkTokens.surfaceContainerLow,
    surfaceContainerHigh: DarkTokens.surfaceContainerHigh,
    surfaceContainerHighest: DarkTokens.surfaceContainerHighest,
    outlineVariant: DarkTokens.outlineVariant,
    stageCompleted: DarkTokens.primary,
    stageActive: DarkTokens.secondaryContainer,
    stagePending: DarkTokens.surfaceContainerHigh,
  );

  @override
  DhColors copyWith({
    Color? gold,
    Color? onGold,
    Color? goldText,
    Color? success,
    Color? successContainer,
    Color? surfaceContainerLowest,
    Color? surfaceContainerLow,
    Color? surfaceContainerHigh,
    Color? surfaceContainerHighest,
    Color? outlineVariant,
    Color? stageCompleted,
    Color? stageActive,
    Color? stagePending,
  }) {
    return DhColors(
      gold: gold ?? this.gold,
      onGold: onGold ?? this.onGold,
      goldText: goldText ?? this.goldText,
      success: success ?? this.success,
      successContainer: successContainer ?? this.successContainer,
      surfaceContainerLowest: surfaceContainerLowest ?? this.surfaceContainerLowest,
      surfaceContainerLow: surfaceContainerLow ?? this.surfaceContainerLow,
      surfaceContainerHigh: surfaceContainerHigh ?? this.surfaceContainerHigh,
      surfaceContainerHighest: surfaceContainerHighest ?? this.surfaceContainerHighest,
      outlineVariant: outlineVariant ?? this.outlineVariant,
      stageCompleted: stageCompleted ?? this.stageCompleted,
      stageActive: stageActive ?? this.stageActive,
      stagePending: stagePending ?? this.stagePending,
    );
  }

  @override
  DhColors lerp(ThemeExtension<DhColors>? other, double t) {
    if (other is! DhColors) return this;
    return DhColors(
      gold: Color.lerp(gold, other.gold, t)!,
      onGold: Color.lerp(onGold, other.onGold, t)!,
      goldText: Color.lerp(goldText, other.goldText, t)!,
      success: Color.lerp(success, other.success, t)!,
      successContainer: Color.lerp(successContainer, other.successContainer, t)!,
      surfaceContainerLowest:
          Color.lerp(surfaceContainerLowest, other.surfaceContainerLowest, t)!,
      surfaceContainerLow: Color.lerp(surfaceContainerLow, other.surfaceContainerLow, t)!,
      surfaceContainerHigh: Color.lerp(surfaceContainerHigh, other.surfaceContainerHigh, t)!,
      surfaceContainerHighest:
          Color.lerp(surfaceContainerHighest, other.surfaceContainerHighest, t)!,
      outlineVariant: Color.lerp(outlineVariant, other.outlineVariant, t)!,
      stageCompleted: Color.lerp(stageCompleted, other.stageCompleted, t)!,
      stageActive: Color.lerp(stageActive, other.stageActive, t)!,
      stagePending: Color.lerp(stagePending, other.stagePending, t)!,
    );
  }
}

extension DhColorsX on BuildContext {
  DhColors get dh => Theme.of(this).extension<DhColors>()!;
  ColorScheme get scheme => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
}

abstract final class AppTheme {
  /// The source system used Google Sans for UI and mandated a monospace face for every SKU,
  /// weight, dimension and timestamp. Product Sans is not licensable, so Inter stands in for
  /// the UI face; the monospace rule is kept exactly because it carries real meaning here.
  static TextTheme _textTheme(Brightness b) {
    final base = b == Brightness.light
        ? ThemeData.light().textTheme
        : ThemeData.dark().textTheme;
    return GoogleFonts.interTextTheme(base).copyWith(
      displayLarge: GoogleFonts.inter(
          fontSize: 44, fontWeight: FontWeight.w700, letterSpacing: -1.2, height: 1.05),
      displayMedium: GoogleFonts.inter(
          fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -0.8, height: 1.1),
      headlineLarge: GoogleFonts.inter(
          fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.5),
      headlineMedium: GoogleFonts.inter(
          fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.3),
      headlineSmall: GoogleFonts.inter(
          fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.2),
      titleMedium: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
      bodyLarge: GoogleFonts.inter(fontSize: 15, height: 1.5),
      bodyMedium: GoogleFonts.inter(fontSize: 14, height: 1.5),
      bodySmall: GoogleFonts.inter(fontSize: 12.5, height: 1.45),
      // Uppercase micro-labels sitting above a value — the source system's signature pair.
      labelSmall: GoogleFonts.jetBrainsMono(
          fontSize: 10.5, fontWeight: FontWeight.w500, letterSpacing: 1.1),
      labelMedium: GoogleFonts.jetBrainsMono(
          fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.6),
    );
  }

  /// Every SKU, weight, dimension, carat and timestamp. Not decoration — the source system
  /// mandated it so operators can compare digits down a column.
  static TextStyle mono({
    double size = 13,
    FontWeight weight = FontWeight.w500,
    Color? color,
  }) =>
      GoogleFonts.jetBrainsMono(
        fontSize: size,
        fontWeight: weight,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static ThemeData light() => _build(
        brightness: Brightness.light,
        scheme: const ColorScheme.light(
          primary: LightTokens.primary,
          onPrimary: LightTokens.onPrimary,
          primaryContainer: LightTokens.primaryContainer,
          onPrimaryContainer: LightTokens.onPrimaryContainer,
          secondary: LightTokens.secondary,
          onSecondary: LightTokens.onSecondary,
          secondaryContainer: LightTokens.secondaryContainer,
          onSecondaryContainer: LightTokens.onSecondary,
          tertiary: LightTokens.secondary,
          onTertiary: LightTokens.onSecondary,
          error: LightTokens.error,
          onError: LightTokens.onError,
          errorContainer: LightTokens.errorContainer,
          onErrorContainer: LightTokens.onErrorContainer,
          surface: LightTokens.surface,
          onSurface: LightTokens.onSurface,
          surfaceContainer: LightTokens.surfaceContainer,
          surfaceContainerHighest: LightTokens.surfaceContainerHighest,
          onSurfaceVariant: LightTokens.onSurfaceVariant,
          outline: LightTokens.outline,
          outlineVariant: LightTokens.outlineVariant,
        ),
        ext: DhColors.light,
      );

  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        scheme: const ColorScheme.dark(
          primary: DarkTokens.primary,
          onPrimary: DarkTokens.onPrimary,
          primaryContainer: DarkTokens.primaryContainer,
          onPrimaryContainer: DarkTokens.onPrimaryContainer,
          secondary: DarkTokens.secondary,
          onSecondary: DarkTokens.onSecondary,
          secondaryContainer: DarkTokens.secondaryContainer,
          onSecondaryContainer: DarkTokens.onSurface,
          tertiary: DarkTokens.tertiary,
          onTertiary: DarkTokens.onTertiary,
          tertiaryContainer: DarkTokens.tertiaryContainer,
          error: DarkTokens.error,
          onError: DarkTokens.onError,
          errorContainer: DarkTokens.errorContainer,
          onErrorContainer: DarkTokens.onErrorContainer,
          surface: DarkTokens.surface,
          onSurface: DarkTokens.onSurface,
          surfaceContainer: DarkTokens.surfaceContainer,
          surfaceContainerHighest: DarkTokens.surfaceContainerHighest,
          onSurfaceVariant: DarkTokens.onSurfaceVariant,
          outline: DarkTokens.outline,
          outlineVariant: DarkTokens.outlineVariant,
        ),
        ext: DhColors.dark,
      );

  static ThemeData _build({
    required Brightness brightness,
    required ColorScheme scheme,
    required DhColors ext,
  }) {
    final text = _textTheme(brightness);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text,
      extensions: [ext],
      splashFactory: InkSparkle.splashFactory,

      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: text.headlineSmall?.copyWith(color: scheme.onSurface),
      ),

      // The source spec was explicit: cards take a 1px border and no shadow.
      cardTheme: CardThemeData(
        color: ext.surfaceContainerLowest,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.rLg,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: const RoundedRectangleBorder(borderRadius: Radii.rMd),
          textStyle: text.titleMedium,
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: const RoundedRectangleBorder(borderRadius: Radii.rMd),
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: text.titleMedium,
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ext.surfaceContainerLow,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: Radii.rMd,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: Radii.rMd,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: Radii.rMd,
          borderSide: BorderSide(color: scheme.secondary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: Radii.rMd,
          borderSide: BorderSide(color: scheme.error),
        ),
        labelStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),

      chipTheme: ChipThemeData(
        shape: const RoundedRectangleBorder(borderRadius: Radii.rFull),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: text.labelMedium,
      ),

      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: ext.surfaceContainerHighest,
      ),
    );
  }
}
