/// The workspace console's front page: the workshop's figures and where to go next.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:dhanaos/admin/admin_repository.dart';
import 'package:dhanaos/admin/admin_router.dart';
import 'package:dhanaos/admin/widgets/admin_widgets.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/shared/widgets/data_pair.dart';
import 'package:dhanaos/shared/widgets/dh_card.dart';

final class OverviewPage extends ConsumerWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    final orgId = user?.orgId;
    if (orgId == null) return const SizedBox.shrink();

    // v_platform_tenants runs as the caller, so a workspace admin gets exactly their own row.
    final summary = ref.watch(tenantProvider(orgId));
    final org = ref.watch(workspaceOrgProvider(orgId));

    return AdminPage(
      title: user!.orgName ?? 'Workspace',
      subtitle: 'Signed in as ${user.fullName}, administrator.',
      actions: [
        OutlinedButton.icon(
          onPressed: () => context.go(AdminPaths.newCustomer),
          icon: const Icon(Icons.add_business_outlined),
          label: const Text('Add customer'),
        ),
        FilledButton.icon(
          onPressed: () => context.go(AdminPaths.newMember),
          icon: const Icon(Icons.person_add_alt_rounded),
          label: const Text('Add member'),
        ),
      ],
      children: [
        AsyncBody<TenantSummary>(
          value: summary,
          what: 'The workspace figures',
          onRetry: () => ref.invalidate(tenantProvider(orgId)),
          builder: (t) => StatRow(
            children: [
              StatTile(
                label: 'Team',
                value: '${t.activeMembers}',
                hint: '${t.admins} admin(s) · active logins',
                onTap: () => context.go(AdminPaths.team),
              ),
              StatTile(
                label: 'Customers',
                value: '${t.customers}',
                onTap: () => context.go(AdminPaths.customers),
              ),
              StatTile(
                label: 'Partners',
                value: '${t.partners}',
                onTap: () => context.go(AdminPaths.partners),
              ),
              StatTile(label: 'Open jobs', value: '${t.openJobs}', hint: 'Managed in the app'),
            ],
          ),
        ),
        AsyncBody<Org>(
          value: org,
          what: 'The workspace profile',
          onRetry: () => ref.invalidate(workspaceOrgProvider(orgId)),
          builder: (o) => DhSectionCard(
            title: 'Invoice profile',
            subtitle: 'What every tax invoice prints (D-004).',
            action: TextButton(
              onPressed: () => context.go(AdminPaths.organisation),
              child: const Text('Edit'),
            ),
            child: DataPairGrid(
              columns: 3,
              children: [
                DataPair(label: 'Legal name', value: o.legalName ?? DataPair.placeholder),
                DataPair.mono(label: 'GSTIN', value: o.gstin ?? DataPair.placeholder),
                DataPair.mono(label: 'PAN', value: o.pan ?? DataPair.placeholder),
                DataPair(
                  label: 'City',
                  value: (o.address['city'] as String?) ?? DataPair.placeholder,
                ),
                DataPair(
                  label: 'State',
                  value: (o.address['state'] as String?) ?? DataPair.placeholder,
                ),
                DataPair.mono(label: 'Base currency', value: o.baseCurrency),
              ],
            ),
          ),
        ),
        DhCard(
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded, color: context.scheme.onSurfaceVariant),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  'Jobs, production, QC and dispatch are run from the DhanaOS app. This panel '
                  'manages who can sign in to it and the records their work refers to.',
                  style: context.text.bodyMedium?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
