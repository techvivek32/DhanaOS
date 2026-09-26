/// One responsive shell, not two products.
///
/// The 46 mockups shipped as two separate exports — 38 desktop screens in the light palette and
/// 8 mobile screens under a different brand — with no shared chrome and no breakpoint between
/// them. D-010 rejects that split: one component set, one navigation model, two token sets. So
/// this file holds a single shell that becomes a 260px sidebar at [wideBreakpoint] and a bottom
/// bar below it, over the same branch navigators.
///
/// Two source defects are corrected here rather than ported:
///
///  * The sidebar had **no width at all**. Every export wrote `w-[sidebar-width]`, a Tailwind
///    arbitrary-value class that takes a CSS length and not a theme key, so it compiled to
///    nothing. [Spacing.sidebarWidth] is the intended 260px.
///  * Destinations were a static list on every screen. Here they are filtered by the session
///    user's principal class and roles (D-008), so a vendor never sees an internal rail.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/app_user.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/shared/shell/top_bar.dart';

/// Which roles open which area.
///
/// An empty list means "any internal user". Admin always passes and is therefore never listed —
/// see [NavArea.opensFor]. None of this replaces RLS, which refuses the rows regardless; it
/// stops an operator walking into a screen that will only ever be empty for them.
abstract final class AreaRoles {
  static const anyInternal = <UserRole>[];

  /// Vendor allocation and the casting/lab queues.
  static const partnerDesk = <UserRole>[
    UserRole.engineer,
    UserRole.productionManager,
    UserRole.logistics,
  ];

  /// The vault. Stock movements are money moving, so this is the one nav item with teeth.
  static const stock = <UserRole>[
    UserRole.inventoryKeeper,
    UserRole.productionManager,
    UserRole.engineer,
  ];

  static const cad = <UserRole>[
    UserRole.cadDesigner,
    UserRole.engineer,
    UserRole.productionManager,
  ];

  static const qc = <UserRole>[
    UserRole.qcInspector,
    UserRole.engineer,
    UserRole.productionManager,
  ];

  /// Certification hand-offs and insured dispatch.
  static const logistics = <UserRole>[
    UserRole.logistics,
    UserRole.productionManager,
    UserRole.engineer,
  ];

  /// Creating a job order commits a code from the org sequence (D-001), so it is not open to
  /// everyone who can read the board.
  static const intake = <UserRole>[
    UserRole.engineer,
    UserRole.productionManager,
  ];
}

/// The shell's branches, in the exact order `core/router.dart` declares them.
///
/// [StatefulShellRoute.indexedStack] addresses branches by integer index, so the router builds
/// its branch list by iterating `NavArea.values`. Reordering this enum reorders the branches
/// with it, and nothing can drift.
///
/// The wide rail and the bottom bar carry different labels for the same destination because the
/// two mockup exports named them differently — "Flow" and "Production" are one board, "Stock"
/// and "Inventory" are one vault. (The desktop sidebar called that slot "Files"; it is the stock
/// vault, so it is named for what it is.)
enum NavArea {
  dashboard(
    label: 'Dashboard',
    short: 'Dash',
    icon: Icons.space_dashboard_outlined,
    activeIcon: Icons.space_dashboard,
    path: Paths.dashboard,
    bottomOrder: 0,
  ),
  production(
    label: 'Production',
    short: 'Flow',
    icon: Icons.account_tree_outlined,
    activeIcon: Icons.account_tree,
    path: Paths.production,
    bottomOrder: 1,
  ),
  jobs(
    label: 'Jobs',
    short: 'Orders',
    icon: Icons.receipt_long_outlined,
    activeIcon: Icons.receipt_long,
    path: Paths.jobs,
    bottomOrder: 3,
  ),
  partners(
    label: 'Partners',
    short: 'Partners',
    icon: Icons.handshake_outlined,
    activeIcon: Icons.handshake,
    path: Paths.partner,
    allow: AreaRoles.partnerDesk,
  ),
  inventory(
    label: 'Inventory',
    short: 'Stock',
    icon: Icons.inventory_2_outlined,
    activeIcon: Icons.inventory_2,
    path: Paths.inventory,
    bottomOrder: 2,
    allow: AreaRoles.stock,
  ),
  portal(
    label: 'Client Portal',
    short: 'Portal',
    icon: Icons.storefront_outlined,
    activeIcon: Icons.storefront,
    path: Paths.portal,
    internal: false,
  ),
  settings(
    label: 'Settings',
    short: 'Settings',
    icon: Icons.settings_outlined,
    activeIcon: Icons.settings,
    path: Paths.settings,
  );

  const NavArea({
    required this.label,
    required this.short,
    required this.icon,
    required this.activeIcon,
    required this.path,
    this.bottomOrder,
    this.internal = true,
    this.allow = AreaRoles.anyInternal,
  });

  /// Sidebar label.
  final String label;

  /// Bottom-bar label. Short enough not to ellipsize on a 360px phone.
  final String short;

  final IconData icon;
  final IconData activeIcon;

  /// The branch's initial location.
  final String path;

  /// Position in the bottom bar, or null to keep it off the bar entirely. The mockups' mobile
  /// bar was Dash / Flow / Stock / Orders, in that order.
  final int? bottomOrder;

  /// False for the retailer's portal, which is never part of the internal rail.
  final bool internal;

  /// Any one of these roles opens the area; empty means any internal user.
  final List<UserRole> allow;

  int get branchIndex => index;

  bool opensFor(AppUser user) =>
      user.isAdmin || allow.isEmpty || user.hasAnyRole(allow);

  /// D-008. A partner principal gets exactly one destination — their own queue — and a customer
  /// principal gets the portal. Neither is offered a rail they cannot legally follow.
  static List<NavArea> visibleTo(AppUser? user) {
    if (user == null) return const <NavArea>[];
    return switch (user.principal) {
      PrincipalClass.partner => const <NavArea>[NavArea.partners],
      PrincipalClass.customer => const <NavArea>[NavArea.portal],
      PrincipalClass.internal => <NavArea>[
          for (final area in NavArea.values)
            if (area.internal && area.opensFor(user)) area,
        ],
    };
  }
}

final class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// Below this the rail folds into a bottom bar. 1000 rather than a tablet-ish 600 because the
  /// production board and the job table both need ~740px of content beside a 260px rail before
  /// they stop being useful.
  static const wideBreakpoint = 1000.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // D-008: the one source of identity in the app. Nothing here falls back to a literal — the
    // rail an operator sees is built from the roles the server actually returned for them.
    final user = ref.watch(currentUserProvider).valueOrNull;
    final areas = NavArea.visibleTo(user);
    final current = NavArea.values[navigationShell.currentIndex];
    final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;

    void select(NavArea area) => navigationShell.goBranch(
          area.branchIndex,
          // Tapping the destination you are already in returns to its root, which is what an
          // operator three screens deep into Jobs expects from a second tap.
          initialLocation: area.branchIndex == navigationShell.currentIndex,
        );

    // A rail with one destination is a decoration. External principals reach exactly one area
    // (D-008), so they get the content full-width and sign out from the identity chip.
    final showRail = areas.length > 1;

    if (wide) {
      return Scaffold(
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showRail) ...[
                _Sidebar(
                  areas: areas,
                  current: current,
                  user: user,
                  onSelect: select,
                ),
                VerticalDivider(width: 1, color: context.dh.outlineVariant),
              ],
              Expanded(
                child: Column(
                  children: [
                    TopBar(wide: true, area: current),
                    Divider(height: 1, color: context.dh.outlineVariant),
                    Expanded(child: navigationShell),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final bottom = _bottomAreas(areas, current);
    // _bottomAreas guarantees `current` is in the list, so this is only belt-and-braces against
    // NavigationBar's assert that selectedIndex is in range.
    final selected = bottom.indexOf(current);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            TopBar(wide: false, area: current),
            Divider(height: 1, color: context.dh.outlineVariant),
            Expanded(child: navigationShell),
          ],
        ),
      ),
      // A single-destination bar is noise, so external principals get none: their whole app is
      // one area and the identity chip in the top bar carries sign-out.
      bottomNavigationBar: bottom.length < 2
          ? null
          : NavigationBar(
              selectedIndex: selected < 0 ? 0 : selected,
              onDestinationSelected: (i) => select(bottom[i]),
              destinations: [
                for (final area in bottom)
                  NavigationDestination(
                    icon: Icon(area.icon),
                    selectedIcon: Icon(area.activeIcon),
                    label: area.short,
                  ),
              ],
            ),
    );
  }

  /// The four bar destinations, plus wherever the operator currently is if that is not one of
  /// them. Without the second half, standing in Settings on a phone would light up "Dash".
  static List<NavArea> _bottomAreas(List<NavArea> allowed, NavArea current) {
    final bar = allowed.where((a) => a.bottomOrder != null).toList()
      ..sort((a, b) => a.bottomOrder!.compareTo(b.bottomOrder!));
    if (!bar.contains(current)) bar.add(current);
    return bar;
  }
}

final class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.areas,
    required this.current,
    required this.user,
    required this.onSelect,
  });

  final List<NavArea> areas;
  final NavArea current;
  final AppUser? user;
  final ValueChanged<NavArea> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final signedIn = user;
    // Opening a job order mints a code from the org sequence (D-001), so the button is not
    // offered to everyone who can read the board.
    final canOpenJob = signedIn != null &&
        signedIn.isInternal &&
        (signedIn.isAdmin || signedIn.hasAnyRole(AreaRoles.intake));

    return SizedBox(
      // D-010: the class the mockups used for this compiled to nothing, so the rail shipped with
      // zero width. This is the width the spec always meant.
      width: Spacing.sidebarWidth,
      child: ColoredBox(
        color: context.dh.surfaceContainerLowest,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.md,
                Spacing.md,
                Spacing.sm,
              ),
              child: Row(
                children: [
                  Icon(Icons.diamond_outlined, size: 22, color: context.dh.gold),
                  const SizedBox(width: Spacing.sm),
                  Text(
                    'DhanaOS',
                    style: AppTheme.mono(
                      size: 15,
                      weight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            if (canOpenJob)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.md,
                  Spacing.sm,
                  Spacing.md,
                  Spacing.md,
                ),
                child: FilledButton.icon(
                  onPressed: () => context.go(Paths.newJob),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('New Job Order'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(Spacing.rowHeight),
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.sm,
                  vertical: Spacing.xs,
                ),
                children: [
                  for (final area in areas)
                    _SidebarItem(
                      area: area,
                      selected: area == current,
                      onTap: () => onSelect(area),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: context.dh.outlineVariant),
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Text(
                // D-008, stated where an operator can see it: the mockups leaked one hardcoded
                // identity onto the vendor's screen and the customer's approval screen.
                signedIn == null ? 'Not signed in' : 'Signed in as ${signedIn.fullName}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.area,
    required this.selected,
    required this.onTap,
  });

  final NavArea area;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    // The selected fill is `primary` — pure black in light, metallic gold in dark — because both
    // carry their own high-contrast `onPrimary`. It is the design system's "strong" tone, and a
    // rail has exactly one strong item at a time.
    final fg = selected ? scheme.onPrimary : scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs / 2),
      child: Material(
        // Unselected rows take the rail's own fill rather than a transparency literal, so the
        // ink splash lands on the right ground in both themes.
        color: selected ? scheme.primary : context.dh.surfaceContainerLowest,
        borderRadius: Radii.rMd,
        child: InkWell(
          onTap: onTap,
          borderRadius: Radii.rMd,
          child: Semantics(
            selected: selected,
            button: true,
            child: Container(
              height: Spacing.rowHeight,
              padding: const EdgeInsets.symmetric(horizontal: Spacing.sm + Spacing.xs),
              child: Row(
                children: [
                  Icon(selected ? area.activeIcon : area.icon, size: 20, color: fg),
                  const SizedBox(width: Spacing.sm + Spacing.xs),
                  Expanded(
                    child: Text(
                      area.label,
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
      ),
    );
  }
}
