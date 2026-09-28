import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:dhanaos/core/theme/app_theme.dart';

/// WCAG contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  for (final name in ['light', 'dark']) {
    // A style taken from the raw text theme into a component theme has no colour unless it is
    // given one, and the engine paints a colourless label white — invisible on the light surface.
    testWidgets('filter chip labels are readable in $name', (tester) async {
      final theme = name == 'light' ? AppTheme.light() : AppTheme.dark();
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Row(children: [
            FilterChip(label: const Text('Stage'), selected: false, onSelected: (_) {}),
            FilterChip(label: const Text('Rush'), selected: true, onSelected: (_) {}),
          ]),
        ),
      ));
      // Fonts are not bundled in tests; their load failures are not what this checks.
      while (tester.takeException() != null) {}

      for (final label in ['Stage', 'Rush']) {
        final color = tester
            .widget<RichText>(
                find.descendant(of: find.text(label), matching: find.byType(RichText)))
            .text
            .style
            ?.color;
        expect(color, isNotNull, reason: '$label has no colour in $name');
        expect(_contrast(color!, theme.colorScheme.surface), greaterThanOrEqualTo(4.5),
            reason: '$label is below AA contrast in $name');
      }
    });
  }
}
