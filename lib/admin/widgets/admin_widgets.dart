/// The admin panel's building blocks, on the app's own design system (D-010): the same tokens,
/// cards and chips, laid out for a desktop browser.
///
/// Imports widget files one by one rather than the `widgets.dart` barrel, which also exports the
/// device-only audio recorder.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/admin/admin_repository.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/shared/widgets/dh_card.dart';
import 'package:dhanaos/shared/widgets/empty_state.dart';

// ================================================================= page

/// A console page: title, one line of context, the page's actions, then the body.
final class AdminPage extends StatelessWidget {
  const AdminPage({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.actions = const [],
    this.leading,
    this.maxWidth = 1120,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? leading;
  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Spacing.xl, Spacing.lg, Spacing.xl, Spacing.xxl),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (leading != null) ...[leading!, const SizedBox(height: Spacing.sm)],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style: context.text.headlineLarge?.copyWith(color: scheme.onSurface),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: Spacing.xs),
                            Text(
                              subtitle!,
                              style: context.text.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (actions.isNotEmpty) ...[
                      const SizedBox(width: Spacing.md),
                      Wrap(
                        spacing: Spacing.sm,
                        runSpacing: Spacing.sm,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: actions,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Spacing.lg),
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(height: Spacing.md),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// "← Team" above a detail page's title.
final class BackLink extends StatelessWidget {
  const BackLink({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.arrow_back_rounded, size: 18),
      label: Text(label),
    ),
  );
}

/// Loading, failed or ready — the three states every read in the panel can be in.
final class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({
    super.key,
    required this.value,
    required this.builder,
    required this.onRetry,
    this.what = 'This',
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;
  final String what;

  @override
  Widget build(BuildContext context) => switch (value) {
    AsyncData(value: final T data) => builder(data),
    AsyncError(error: final error) => ErrorState(
      compact: true,
      title: '$what did not load',
      message: error is DhFailure ? error.message : 'Try again in a moment.',
      detail: error is DhFailure ? error.detail : '$error',
      onRetry: onRetry,
    ),
    _ => const LoadingSkeleton.list(count: 3),
  };
}

// ================================================================= figures

final class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.tone,
    this.onTap,
  });

  final String label;
  final String value;
  final String? hint;
  final Color? tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return DhCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            value,
            style: AppTheme.mono(size: 26, weight: FontWeight.w600, color: tone),
          ),
          if (hint != null) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              hint!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// Tiles in a responsive row: four across on a desktop, fewer as the window narrows.
final class StatRow extends StatelessWidget {
  const StatRow({super.key, required this.children, this.minTileWidth = 200});

  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    // A new workspace has no rates yet; clamp(1, 0) would throw.
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final perRow = (constraints.maxWidth / minTileWidth).floor().clamp(1, children.length);
        final width = (constraints.maxWidth - Spacing.md * (perRow - 1)) / perRow;
        return Wrap(
          spacing: Spacing.md,
          runSpacing: Spacing.md,
          children: [for (final child in children) SizedBox(width: width, child: child)],
        );
      },
    );
  }
}

// ================================================================= table

final class AdminColumn<T> {
  const AdminColumn(this.label, this.cell, {this.flex = 2, this.alignEnd = false});

  final String label;
  final Widget Function(BuildContext context, T row) cell;
  final int flex;
  final bool alignEnd;
}

/// A list as a table: a mono header, hairline rows, the whole row clickable.
final class AdminTable<T> extends StatelessWidget {
  const AdminTable({
    super.key,
    required this.columns,
    required this.rows,
    this.onTap,
    this.emptyTitle = 'Nothing here yet',
    this.emptyMessage = '',
    this.emptyIcon = Icons.inbox_outlined,
  });

  final List<AdminColumn<T>> columns;
  final List<T> rows;
  final void Function(T row)? onTap;
  final String emptyTitle;
  final String emptyMessage;
  final IconData emptyIcon;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    if (rows.isEmpty) {
      return DhCard(
        child: EmptyState(compact: true, icon: emptyIcon, title: emptyTitle, message: emptyMessage),
      );
    }

    Widget line(List<Widget> cells) => Row(
      children: [
        for (var i = 0; i < columns.length; i++)
          Expanded(
            flex: columns[i].flex,
            child: Align(
              alignment: columns[i].alignEnd ? Alignment.centerRight : Alignment.centerLeft,
              child: cells[i],
            ),
          ),
      ],
    );

    return DhCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Container(
            color: dh.surfaceContainerLow,
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm + 2),
            child: line([
              for (final c in columns)
                Text(
                  c.label.toUpperCase(),
                  style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
            ]),
          ),
          for (final row in rows) ...[
            Divider(height: 1, color: dh.outlineVariant),
            InkWell(
              onTap: onTap == null ? null : () => onTap!(row),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
                  child: line([for (final c in columns) c.cell(context, row)]),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A name with a quieter second line — "Elena Rostova / elena@auraforge.example".
final class TwoLine extends StatelessWidget {
  const TwoLine(this.primary, this.secondary, {super.key, this.monoSecondary = false});

  final String primary;
  final String? secondary;
  final bool monoSecondary;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          primary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.text.bodyLarge?.copyWith(
            color: scheme.onSurface,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (secondary != null && secondary!.isNotEmpty)
          Text(
            secondary!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monoSecondary
                ? AppTheme.mono(size: 12, color: scheme.onSurfaceVariant)
                : context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
      ],
    );
  }
}

// ================================================================= roles

/// What each workspace role unlocks, in the words of `features/auth/permissions.dart`.
String roleDescription(UserRole role) => switch (role) {
  UserRole.admin => 'Everything, plus people, roles and workspace settings.',
  UserRole.engineer => 'Approves designs and prices, edits jobs, opens the vault.',
  UserRole.cadDesigner => 'Edits jobs and works the CAD queue.',
  UserRole.productionManager => 'Approves designs, edits jobs and moves stock.',
  UserRole.qcInspector => 'Inspects pieces and authorises QC.',
  UserRole.logistics => 'Certification, shipping and dispatch.',
  UserRole.inventoryKeeper => 'Opens the vault and moves stock.',
  UserRole.benchOperator => 'Completes the bench stages assigned to them.',
  UserRole.partner => 'A vendor login: only the jobs sent to that vendor.',
  UserRole.customer => 'A customer login: only that customer\'s orders.',
};

const workspaceRoles = <UserRole>[
  UserRole.admin,
  UserRole.engineer,
  UserRole.productionManager,
  UserRole.cadDesigner,
  UserRole.qcInspector,
  UserRole.logistics,
  UserRole.inventoryKeeper,
  UserRole.benchOperator,
];

final class RoleChecklist extends StatelessWidget {
  const RoleChecklist({
    super.key,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });

  final Set<UserRole> selected;
  final ValueChanged<Set<UserRole>> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Column(
      children: [
        for (final role in workspaceRoles)
          CheckboxListTile(
            value: selected.contains(role),
            enabled: enabled,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: Text(
              role.label,
              style: context.text.bodyLarge?.copyWith(color: scheme.onSurface),
            ),
            subtitle: Text(
              roleDescription(role),
              style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            onChanged: (on) {
              final next = {...selected};
              if (on ?? false) {
                next.add(role);
              } else {
                next.remove(role);
              }
              onChanged(next);
            },
          ),
      ],
    );
  }
}

// ================================================================= passwords

/// The temporary password an admin hands to a new member. Visible on purpose — the admin has to
/// read it out or paste it — and generated by default so nobody types "password123".
final class TempPasswordField extends StatelessWidget {
  const TempPasswordField({super.key, required this.controller, this.enabled = true});

  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return TextFormField(
      controller: controller,
      enabled: enabled,
      style: AppTheme.mono(size: 15, color: scheme.onSurface),
      decoration: InputDecoration(
        labelText: 'Temporary password',
        helperText: 'They choose their own at first sign-in.',
        suffixIcon: IconButton(
          tooltip: 'Generate another',
          icon: const Icon(Icons.autorenew_rounded),
          onPressed: enabled ? () => controller.text = generateTempPassword() : null,
        ),
      ),
      validator: (value) => (value ?? '').length < 8 ? 'Use at least 8 characters.' : null,
    );
  }
}

/// Shown once, straight after an account is created or a password reset: the only moment the
/// temporary password is on screen.
Future<void> showCredentialsDialog(
  BuildContext context, {
  required String title,
  required String email,
  required String password,
}) => showDialog<void>(
  context: context,
  builder: (context) {
    final scheme = context.scheme;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label.toUpperCase(),
              style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: AppTheme.mono(size: 15, color: scheme.onSurface)),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: () => Clipboard.setData(ClipboardData(text: value)),
          ),
        ],
      ),
    );
    return AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Share these privately. This is the only time the password is shown; they '
              'will be asked to set their own when they first sign in.',
              style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.md),
            row('Email', email),
            row('Temporary password', password),
          ],
        ),
      ),
      actions: [
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      ],
    );
  },
);

// ================================================================= feedback

void showAdminError(BuildContext context, Object error) {
  final message = switch (error) {
    DhFailure(:final message) => message,
    String() => error,
    _ => 'That did not work. Try again.',
  };
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: context.scheme.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
}

void showAdminNotice(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
}

/// Yes or no, phrased as the act. Resolves false on dismiss.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Text(message),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: context.scheme.error,
                  foregroundColor: context.scheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// Asks for a short reason — suspending a tenant has to say why.
Future<String?> reasonDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final controller = TextEditingController();
  final answer = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(message),
            const SizedBox(height: Spacing.md),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: context.scheme.error,
            foregroundColor: context.scheme.onError,
          ),
          onPressed: () {
            final text = controller.text.trim();
            if (text.isNotEmpty) Navigator.of(context).pop(text);
          },
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  controller.dispose();
  return answer;
}
