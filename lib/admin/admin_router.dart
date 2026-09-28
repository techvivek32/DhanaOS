/// The admin panel's address space, and the fence between its two consoles.
///
/// A super admin stands only under `/platform`; a workspace admin only under `/workspace`. Every
/// other state parks on `/`, which explains it. As in the app's router, this decides where a
/// person may stand — RLS and the RPCs decide what they may do.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/admin/admin_identity.dart';
import 'package:dhanaos/admin/pages/gate_pages.dart';
import 'package:dhanaos/admin/pages/platform_pages.dart';
import 'package:dhanaos/admin/pages/workspace_customers.dart';
import 'package:dhanaos/admin/pages/workspace_pages.dart';
import 'package:dhanaos/admin/pages/workspace_settings.dart';
import 'package:dhanaos/admin/pages/workspace_team.dart';
import 'package:dhanaos/admin/shell/admin_shell.dart';
import 'package:dhanaos/shared/widgets/empty_state.dart';

part 'admin_router.g.dart';

abstract final class AdminPaths {
  static const gate = '/';
  static const login = '/login';

  static const platform = '/platform';
  static const newTenant = '/platform/new';
  static String tenant(String orgId) => '/platform/tenants/$orgId';

  static const workspace = '/workspace';
  static const team = '/workspace/team';
  static const newMember = '/workspace/team/new';
  static String newLoginFor({String? customerId, String? partnerId}) => Uri(
    path: newMember,
    queryParameters: {
      if (customerId != null) 'customer': customerId,
      if (partnerId != null) 'partner': partnerId,
    },
  ).toString();
  static String member(String userId) => '/workspace/team/$userId';
  static const customers = '/workspace/customers';
  static const newCustomer = '/workspace/customers/new';
  static String customer(String id) => '/workspace/customers/$id';
  static const partners = '/workspace/partners';
  static const newPartner = '/workspace/partners/new';
  static String partner(String id) => '/workspace/partners/$id';
  static const organisation = '/workspace/organisation';
  static const rates = '/workspace/rates';
  static const resources = '/workspace/resources';

  static bool within(String path, String root) => path == root || path.startsWith('$root/');
}

@Riverpod(keepAlive: true)
GoRouter adminRouter(Ref ref) {
  final refresh = _Refresh();
  ref.listen<AdminGate>(adminGateProvider, (_, __) => refresh.bump());
  ref.onDispose(refresh.dispose);

  GoRoute page(String path, Widget Function(GoRouterState state) build) => GoRoute(
    path: path,
    pageBuilder: (context, state) => NoTransitionPage(child: build(state)),
  );

  return GoRouter(
    initialLocation: AdminPaths.gate,
    refreshListenable: refresh,
    debugLogDiagnostics: kDebugMode,
    redirect: (context, state) => _guard(ref.read(adminGateProvider), state.uri),
    errorBuilder: (context, state) => Scaffold(
      body: EmptyState(
        icon: Icons.wrong_location_outlined,
        title: 'That page does not exist',
        message:
            'Nothing in the admin panel answers to ${state.uri.path}. Check the link, or '
            'start from the console.',
        actionLabel: 'Go to the console',
        onAction: () => context.go(AdminPaths.gate),
      ),
    ),
    routes: [
      GoRoute(path: AdminPaths.gate, builder: (context, state) => const GatePage()),
      GoRoute(path: AdminPaths.login, builder: (context, state) => const AdminLoginPage()),
      ShellRoute(
        builder: (context, state, child) => AdminShell(location: state.uri.path, child: child),
        routes: [
          page(AdminPaths.platform, (_) => const TenantsPage()),
          page(AdminPaths.newTenant, (_) => const NewTenantPage()),
          page('/platform/tenants/:orgId', (s) => TenantPage(orgId: s.pathParameters['orgId']!)),
          page(AdminPaths.workspace, (_) => const OverviewPage()),
          page(AdminPaths.team, (_) => const TeamPage()),
          page(
            AdminPaths.newMember,
            (s) => MemberPage(
              customerId: s.uri.queryParameters['customer'],
              partnerId: s.uri.queryParameters['partner'],
            ),
          ),
          page('/workspace/team/:userId', (s) => MemberPage(userId: s.pathParameters['userId'])),
          page(AdminPaths.customers, (_) => const CustomersPage()),
          page(AdminPaths.newCustomer, (_) => const CustomerPage()),
          page('/workspace/customers/:id', (s) => CustomerPage(customerId: s.pathParameters['id'])),
          page(AdminPaths.partners, (_) => const PartnersPage()),
          page(AdminPaths.newPartner, (_) => const PartnerPage()),
          page('/workspace/partners/:id', (s) => PartnerPage(partnerId: s.pathParameters['id'])),
          page(AdminPaths.organisation, (_) => const OrganisationPage()),
          page(AdminPaths.rates, (_) => const RatesPage()),
          page(AdminPaths.resources, (_) => const ResourcesPage()),
        ],
      ),
    ],
  );
}

String? _guard(AdminGate gate, Uri uri) {
  final path = uri.path;
  // Where the person was going, carried through sign-in and the boot gate, so a refresh or a
  // shared link lands where it points rather than on the console's front page.
  final wanted =
      uri.queryParameters['from'] ??
      (path == AdminPaths.gate || path == AdminPaths.login ? null : uri.toString());
  String park(String at) =>
      wanted == null ? at : Uri(path: at, queryParameters: {'from': wanted}).toString();
  String? console(String root) {
    if (AdminPaths.within(path, root)) return null;
    if (wanted != null && AdminPaths.within(Uri.parse(wanted).path, root)) return wanted;
    return root;
  }

  switch (gate) {
    case AdminGate.signedOut:
      return path == AdminPaths.login ? null : park(AdminPaths.login);
    case AdminGate.platform:
      return console(AdminPaths.platform);
    case AdminGate.workspace:
      return console(AdminPaths.workspace);
    case AdminGate.booting ||
        AdminGate.unconfigured ||
        AdminGate.bootFailed ||
        AdminGate.notAdmin ||
        AdminGate.suspended ||
        AdminGate.deactivated ||
        AdminGate.mustChangePassword ||
        AdminGate.failed:
      return path == AdminPaths.gate ? null : park(AdminPaths.gate);
  }
}

final class _Refresh extends ChangeNotifier {
  void bump() => notifyListeners();
}
