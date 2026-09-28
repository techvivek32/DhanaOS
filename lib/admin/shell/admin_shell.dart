/// The console frame: the app's 260px sidebar (D-010) with the items this administrator may
/// open, and who is signed in at its foot. Below a laptop width the sidebar becomes a drawer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:dhanaos/admin/admin_identity.dart';
import 'package:dhanaos/admin/admin_router.dart';
import 'package:dhanaos/admin/theme_mode.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/features/auth/session.dart';

final class _NavItem {
  const _NavItem(this.label, this.icon, this.path);

  final String label;
  final IconData icon;
  final String path;
}

const _platformItems = [_NavItem('Workspaces', Icons.apartment_outlined, AdminPaths.platform)];

const _workspaceItems = [
  _NavItem('Overview', Icons.space_dashboard_outlined, AdminPaths.workspace),
  _NavItem('Team', Icons.group_outlined, AdminPaths.team),
  _NavItem('Customers', Icons.storefront_outlined, AdminPaths.customers),
  _NavItem('Partners', Icons.handshake_outlined, AdminPaths.partners),
  _NavItem('Organisation', Icons.badge_outlined, AdminPaths.organisation),
  _NavItem('Metal rates', Icons.show_chart_rounded, AdminPaths.rates),
  _NavItem('Benches & machines', Icons.precision_manufacturing_outlined, AdminPaths.resources),
];

final class AdminShell extends ConsumerWidget {
  const AdminShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(adminIdentityProvider).value;
    final items = identity is PlatformAdmin ? _platformItems : _workspaceItems;
    // The longest matching root wins, so /workspace/team/… highlights Team, not Overview.
    final current = items
        .where((i) => AdminPaths.within(location, i.path))
        .fold<_NavItem?>(
          null,
          (best, i) => best == null || i.path.length > best.path.length ? i : best,
        );

    final sidebar = _Sidebar(items: items, current: current, identity: identity);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          return Scaffold(
            body: Row(
              children: [
                sidebar,
                VerticalDivider(width: 1, color: context.dh.outlineVariant),
                Expanded(child: child),
              ],
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(current?.label ?? 'DhanaOS Admin')),
          drawer: Drawer(child: sidebar),
          body: child,
        );
      },
    );
  }
}

final class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.items, required this.current, required this.identity});

  final List<_NavItem> items;
  final _NavItem? current;
  final AdminIdentity? identity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final dh = context.dh;
    final (name, role) = switch (identity) {
      PlatformAdmin(:final fullName) => (fullName, 'Platform super admin'),
      WorkspaceAdmin(:final user) => (user.fullName, 'Admin · ${user.orgName ?? 'Workspace'}'),
      _ => ('', ''),
    };

    return Container(
      width: Spacing.sidebarWidth,
      color: dh.surfaceContainerLowest,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.lg, Spacing.md, Spacing.lg),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: dh.gold, borderRadius: Radii.rMd),
                    child: Icon(Icons.diamond_outlined, size: 18, color: dh.onGold),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Text(
                    'DhanaOS',
                    style: AppTheme.mono(
                      size: 15,
                      weight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text('ADMIN', style: context.text.labelSmall?.copyWith(color: dh.goldText)),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                children: [
                  for (final item in items)
                    _SidebarItem(
                      item: item,
                      selected: item == current,
                      onTap: () {
                        Scaffold.maybeOf(context)?.closeDrawer();
                        context.go(item.path);
                      },
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: dh.outlineVariant),
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ThemeModeSwitch(),
                  const SizedBox(height: Spacing.md),
                  // D-008: the identity on screen is the session's, never a literal.
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    role,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: Spacing.sm),
                  TextButton.icon(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
                    icon: const Icon(Icons.logout_rounded, size: 18),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _SidebarItem extends StatelessWidget {
  const _SidebarItem({required this.item, required this.selected, required this.onTap});

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    // The app shell's rule: the one selected row wears `primary` — black in light, gold in dark.
    final fg = selected ? scheme.onPrimary : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs / 2),
      child: Material(
        color: selected ? scheme.primary : context.dh.surfaceContainerLowest,
        borderRadius: Radii.rMd,
        child: InkWell(
          onTap: onTap,
          borderRadius: Radii.rMd,
          child: Container(
            height: Spacing.rowHeight,
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm + Spacing.xs),
            child: Row(
              children: [
                Icon(item.icon, size: 20, color: fg),
                const SizedBox(width: Spacing.sm + Spacing.xs),
                Expanded(
                  child: Text(
                    item.label,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodyLarge?.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
