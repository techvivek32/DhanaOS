/// My account — who you are signed in as, your own password, and the way out.
///
/// Everything on this screen comes from [currentUserProvider] (D-008). Workspace administration
/// — people, roles, customers, partners — lives in the web admin panel, not here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/features/auth/auth_banner.dart';
import 'package:dhanaos/features/auth/password_form.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

final class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    final notice = ref.watch(authControllerProvider).value?.notice;
    if (user == null) return const LoadingSkeleton.list(count: 2);

    final scheme = context.scheme;
    final roles = user.roles.toList()..sort((a, b) => a.index.compareTo(b.index));

    return ListView(
      padding: const EdgeInsets.all(Spacing.md),
      children: [
        DhSectionCard(
          title: 'Signed in as',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(user.fullName,
                  style: context.text.headlineSmall?.copyWith(color: scheme.onSurface)),
              if (user.title != null) ...[
                const SizedBox(height: Spacing.xs),
                Text(user.title!,
                    style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ],
              const SizedBox(height: Spacing.md),
              DataPairGrid(
                children: [
                  DataPair.mono(label: 'Email', value: user.email ?? DataPair.placeholder),
                  DataPair.mono(label: 'Phone', value: user.phone ?? DataPair.placeholder),
                  DataPair(label: 'Workspace', value: user.orgName ?? DataPair.placeholder),
                ],
              ),
              if (roles.isNotEmpty) ...[
                const SizedBox(height: Spacing.md),
                Text('ROLES',
                    style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.sm,
                  runSpacing: Spacing.sm,
                  children: [
                    for (final role in roles)
                      StatusChip(label: role.label, tone: ChipTone.neutral, dense: true),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        DhSectionCard(
          title: 'Change password',
          subtitle: 'Signs you in with the new one from now on, on every device.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (notice != null) ...[
                AuthBanner(message: notice, tone: AuthBannerTone.info),
                const SizedBox(height: Spacing.md),
              ],
              const NewPasswordForm(),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        OutlinedButton.icon(
          onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Sign out'),
        ),
        const SizedBox(height: Spacing.lg),
        Text(
          'People, roles, customers and partners are managed by your workspace admin in the '
          'DhanaOS admin panel.',
          textAlign: TextAlign.center,
          style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
