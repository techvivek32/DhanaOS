/// Who draws the CAD.
///
/// `job_order_created` ended on "Next Step: CAD — Unassigned" and an "Assign CAD Designer"
/// button that went nowhere: there was no picker, no directory, and — because all 46 mockups
/// hardcoded one identity — no notion that the workshop has more than one person in it.
///
/// D-008 shapes what this sheet can honestly show. `roles_read` only exposes `user_roles` to
/// admins, so a production manager opening this gets the org's people with no role labels rather
/// than an empty list. `DesignerDirectory.rolesVisible` says which of the two happened, and the
/// sheet prints the difference instead of implying the workshop has no designers.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/intake/intake_gateway.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// Opens the picker. Returns the chosen designer, or null if the operator backed out.
Future<AppUser?> pickCadDesigner(BuildContext context, {String? selectedId}) {
  return showModalBottomSheet<AppUser>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: 0.85,
      child: _DesignerSheet(selectedId: selectedId),
    ),
  );
}

final class _DesignerSheet extends ConsumerWidget {
  const _DesignerSheet({this.selectedId});

  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(cadDesignerDirectoryProvider);

    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Assign the CAD',
                  style: context.text.headlineSmall
                      ?.copyWith(color: context.scheme.onSurface),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  'The first stage of the rail. Whoever takes it draws from the references '
                  'captured on step 2.',
                  style: context.text.bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Expanded(
            child: async.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(Spacing.md),
                child: LoadingSkeleton.list(count: 4),
              ),
              error: (error, _) => ErrorState(
                title: 'The team directory did not load',
                message: error is DhFailure
                    ? error.message
                    : 'DhanaOS could not read the list of people in this workshop.',
                detail: error is DhFailure ? error.detail : error.toString(),
                onRetry: () => ref.invalidate(cadDesignerDirectoryProvider),
                retryLabel: 'Try again',
              ),
              data: (directory) => _List(directory: directory, selectedId: selectedId),
            ),
          ),
        ],
      ),
    );
  }
}

final class _List extends StatelessWidget {
  const _List({required this.directory, required this.selectedId});

  final DesignerDirectory directory;
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    if (directory.isEmpty) {
      return const EmptyState(
        icon: Icons.person_search_outlined,
        title: 'Nobody to assign yet',
        message: 'This workshop has no active internal users other than you. Add the team in '
            'Settings and they will appear here.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.md),
      children: [
        NoteStrip(text: directory.note),
        const Gap.md(),
        if (directory.designers.isNotEmpty) ...[
          Text(
            'CAD DESIGNERS',
            style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const Gap.sm(),
          for (final user in directory.designers) ...[
            _DesignerTile(user: user, selected: user.id == selectedId),
            const SizedBox(height: Spacing.sm),
          ],
          const Gap.md(),
        ],
        if (directory.others.isNotEmpty) ...[
          Text(
            directory.rolesVisible ? 'EVERYONE ELSE' : 'THE TEAM',
            style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const Gap.sm(),
          for (final user in directory.others) ...[
            _DesignerTile(user: user, selected: user.id == selectedId),
            const SizedBox(height: Spacing.sm),
          ],
        ],
      ],
    );
  }
}

final class _DesignerTile extends StatelessWidget {
  const _DesignerTile({required this.user, required this.selected});

  final AppUser user;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return SelectableTile(
      title: user.fullName,
      blurb: user.subtitle,
      selected: selected,
      inGroup: true,
      leading: Container(
        decoration: BoxDecoration(
          color: context.dh.surfaceContainerHigh,
          borderRadius: Radii.rMd,
        ),
        alignment: Alignment.center,
        child: Text(
          user.displayInitials,
          style: AppTheme.mono(
            size: 13,
            weight: FontWeight.w700,
            color: context.scheme.onSurfaceVariant,
          ),
        ),
      ),
      onTap: () => Navigator.of(context).pop(user),
    );
  }
}
