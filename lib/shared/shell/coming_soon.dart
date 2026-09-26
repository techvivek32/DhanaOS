/// The placeholder a declared route falls back to until its feature screen lands.
///
/// Every route in `core/router.dart` is declared from day one — the D-008 principal fences and
/// the responsive shell only mean something if the whole address space exists. Areas that have
/// not been built yet render this instead of a missing import, so the APK always compiles and an
/// operator who taps into an unfinished corner is told the truth rather than shown a blank page.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

final class ComingSoon extends StatelessWidget {
  const ComingSoon({
    super.key,
    required this.area,
    this.note,
    this.path,
    this.standalone = false,
  });

  /// What the operator was trying to reach — "Quality Control", "Certification".
  final String area;

  /// Overrides the default explanation when a particular area needs its own.
  final String? note;

  /// The route that resolved here. Shown in mono so a build-out ticket can quote it exactly.
  final String? path;

  /// True for routes that sit outside the app shell (sign-in, the intake wizard), which have no
  /// surrounding [Scaffold] of their own.
  final bool standalone;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        Expanded(
          child: EmptyState(
            icon: Icons.construction_outlined,
            title: '$area is not built yet',
            message: note ??
                'The route, the role check and the shell around it are real — the $area screen '
                    'itself lands in a later phase. Nothing you entered elsewhere is affected.',
          ),
        ),
        if (path != null) ...[
          const SizedBox(height: Spacing.sm),
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.lg),
            child: Text(
              path!,
              textAlign: TextAlign.center,
              style: AppTheme.mono(size: 11, color: context.scheme.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );

    if (!standalone) return body;
    return Scaffold(appBar: AppBar(title: Text(area)), body: SafeArea(child: body));
  }
}
