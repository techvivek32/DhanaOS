/// The address space and the D-008 fences between its principals.
///
/// D-008 is enforced twice over. Postgres RLS decides which rows a principal may *read* and is
/// the only authority that matters; this redirect decides where a principal may *stand*, so an
/// operator is never dropped onto a screen that can only ever come back empty. The mockups had
/// neither: all 46 screens hardcoded "Ravi S. — Manufacturing Engineer", and that one identity
/// leaked onto the external vendor's dashboard and onto the customer's approval screen.
///
/// Identity is not resolved here. `features/auth/session.dart` owns that — one
/// `currentUserProvider`, no fallback literal — and this file reads it. Two session layers
/// would be two answers to "who is this", which is the defect D-008 exists to prevent.
///
/// Every route is declared from day one, even where the screen behind it is still being built,
/// because the fences only mean something if the whole address space exists. Unbuilt areas
/// render [ComingSoon]; swapping in the real screen is a one-line change at the marked
/// `builder`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/app_user.dart';
import 'package:dhanaos/features/auth/login_screen.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/features/auth/splash_screen.dart';
import 'package:dhanaos/features/dashboard/dashboard_screen.dart';
import 'package:dhanaos/features/partner/casting_job.dart';
import 'package:dhanaos/features/partner/partner_queue.dart';
import 'package:dhanaos/features/portal/portal_job.dart';
import 'package:dhanaos/features/portal/portal_jobs.dart';
import 'package:dhanaos/features/production/production_board.dart';
import 'package:dhanaos/shared/shell/app_shell.dart';
import 'package:dhanaos/shared/shell/coming_soon.dart';
import 'package:dhanaos/shared/shell/no_access.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

part 'router.g.dart';

// ---------------------------------------------------------------- addresses

/// Every location in the app, in one list. Nothing anywhere else writes a path literal.
abstract final class Paths {
  /// The boot gate. Holds the first frame while Supabase starts and the stored session is
  /// restored, then hands off to [homeFor]. It exists so the redirect has somewhere loop-free
  /// to park, and so the four auth states that are not a destination have a screen that
  /// explains them.
  static const splash = '/';
  static const login = '/login';

  static const dashboard = '/dashboard';
  static const production = '/production';
  static const jobs = '/jobs';
  static const newJob = '/jobs/new';
  static const inventory = '/inventory';
  static const partner = '/partner';
  static const portal = '/portal';
  static const settings = '/settings';

  static String job(String id) => '/jobs/$id';
  static String newJobStep(int step) => '/jobs/new/step/$step';
  static String cad(String revisionId) => '/cad/$revisionId';
  static String qc(String jobId) => '/qc/$jobId';
  static String certification(String jobId) => '/certification/$jobId';
  static String shipping(String jobId) => '/shipping/$jobId';
  static String partnerJob(String jobId) => '/partner/$jobId';
  static String portalJob(String jobId) => '/portal/$jobId';

  /// The job list reads `q` and filters on job code, customer and assignee — the three things
  /// the mockups' search placeholder promised and never delivered.
  static String jobSearch(String query) => '/jobs?q=${Uri.encodeQueryComponent(query)}';

  /// D-008. Where a principal lands after sign-in, and the only place a fence bounces them to.
  static String homeFor(AppUser user) => switch (user.principal) {
        PrincipalClass.internal => dashboard,
        PrincipalClass.partner => partner,
        PrincipalClass.customer => portal,
      };

  /// True when [path] is [root] or sits underneath it. Used by the fences, so
  /// `/partnership-notes` can never be mistaken for a child of `/partner`.
  static bool within(String path, String root) => path == root || path.startsWith('$root/');
}

/// Route names, for `context.goNamed`. Names survive a path change; paths do not.
abstract final class RouteNames {
  static const splash = 'splash';
  static const login = 'login';
  static const dashboard = 'dashboard';
  static const production = 'production';
  static const jobs = 'jobs';
  static const jobDetail = 'job-detail';
  static const newJob = 'job-new';
  static const newJobStep = 'job-new-step';
  static const cad = 'cad';
  static const qc = 'qc';
  static const certification = 'certification';
  static const shipping = 'shipping';
  static const inventory = 'inventory';
  static const partner = 'partner';
  static const partnerJob = 'partner-job';
  static const portal = 'portal';
  static const portalJob = 'portal-job';
  static const settings = 'settings';
}

// ---------------------------------------------------------------- role gate

/// Renders [child] when the session user's roles open this area, and [NoAccess] when they do
/// not — keeping the URL, so a colleague who does hold the role can open the same link.
///
/// External principals are never role-checked here: they are already fenced to their own area
/// by the redirect, and their permissions are `user_roles`-free by design.
final class RoleGate extends ConsumerWidget {
  const RoleGate.area(NavArea this.area, {super.key, required this.child})
      : label = null,
        allow = null;

  const RoleGate.custom({
    super.key,
    required String this.label,
    required List<UserRole> this.allow,
    required this.child,
  }) : area = null;

  final NavArea? area;
  final String? label;
  final List<UserRole>? allow;
  final Widget child;

  String get _label => area?.label ?? label!;
  List<UserRole> get _allow => area?.allow ?? allow!;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).valueOrNull;
    // No profile yet: the redirect is already moving us. Painting an error here would flash.
    if (user == null) return const SizedBox.shrink();
    if (!user.isInternal) return child;

    final allowed = user.isAdmin || _allow.isEmpty || user.hasAnyRole(_allow);
    if (allowed) return child;

    return NoAccess(
      area: _label,
      needs: _allow,
      onBack: () => context.go(Paths.homeFor(user)),
    );
  }
}

// ---------------------------------------------------------------- router

final _rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// One navigator per branch, so Jobs keeps its scroll position while you take a call in QC.
final _branchKeys = <GlobalKey<NavigatorState>>[
  for (final area in NavArea.values) GlobalKey<NavigatorState>(debugLabel: area.name),
];

@Riverpod(keepAlive: true)
GoRouter router(Ref ref) {
  final refresh = _RouterRefresh();
  // The only thing that re-runs the redirect. Listening to the gate rather than to the raw auth
  // stream means an hourly token refresh — same user, same gate — does not re-decide anything,
  // and so cannot throw an operator out of a half-filled form.
  ref.listen<AuthGate>(authGateProvider, (_, __) => refresh.bump());
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: Paths.splash,
    refreshListenable: refresh,
    debugLogDiagnostics: kDebugMode,
    redirect: (context, state) => _guard(ref, state),
    errorBuilder: (context, state) => _UnknownRoute(location: state.uri.toString()),
    routes: <RouteBase>[
      GoRoute(
        path: Paths.splash,
        name: RouteNames.splash,
        builder: (context, state) => SplashScreen(
          // SplashScreen's documented hand-off. The gate can settle in the same frame this
          // route was built, before the bump above reaches the redirect; navigating from the
          // callback closes that race. The redirect agrees with it, so a double hand-off is a
          // no-op rather than a loop.
          onResolved: (gate) => context.go(_landingFor(ref, gate)),
        ),
      ),
      GoRoute(
        path: Paths.login,
        name: RouteNames.login,
        builder: (context, state) => const LoginScreen(),
      ),

      // The intake wizard runs full screen on the root navigator — it carries its own stepper
      // chrome and must not sit inside the shell. Declared before the shell so `/jobs/new`
      // matches here rather than being read as a job with the id "new".
      GoRoute(
        path: Paths.newJob,
        name: RouteNames.newJob,
        // Fill in: lib/features/intake/intake_wizard.dart -> const IntakeWizard()
        builder: (context, state) => const ComingSoon(
          area: 'New Job Order',
          standalone: true,
          path: Paths.newJob,
          note: 'The 11-step intake wizard lands with the intake feature. D-011 rule 4 gates '
              'its media step: a photo, a voice note or an uploaded file — any one of the '
              'three — before Continue.',
        ),
        routes: <RouteBase>[
          GoRoute(
            path: 'step/:n',
            name: RouteNames.newJobStep,
            // Fill in: IntakeWizard(step: step)
            builder: (context, state) {
              final step = int.tryParse(state.pathParameters['n'] ?? '') ?? 1;
              return ComingSoon(
                area: 'New Job Order — step $step',
                standalone: true,
                path: Paths.newJobStep(step),
              );
            },
          ),
        ],
      ),

      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        // Branch order is NavArea's order, by construction — see NavArea's doc comment.
        branches: <StatefulShellBranch>[
          for (final area in NavArea.values)
            StatefulShellBranch(
              navigatorKey: _branchKeys[area.branchIndex],
              routes: _branchRoutes(area),
            ),
        ],
      ),
    ],
  );
}

/// The D-008 fences.
///
/// Deliberately total: every branch either returns null or returns a path that itself satisfies
/// the branch, so no input can produce a redirect loop. Role checks are *not* done here — they
/// happen in [RoleGate] at build time, which keeps the URL intact and lets the screen explain
/// itself.
String? _guard(Ref ref, GoRouterState state) {
  final path = state.uri.path;

  // The five gate states that are not a destination — still booting, built without
  // `--dart-define`, initialisation threw, the profile read was refused, or the account has no
  // `app_users` row — all park on the splash, which renders each one in words an operator can
  // act on.
  final parked = switch (ref.read(authGateProvider)) {
    AuthGate.booting ||
    AuthGate.unconfigured ||
    AuthGate.bootFailed ||
    AuthGate.unprovisioned ||
    AuthGate.profileBlocked =>
      Paths.splash,
    AuthGate.signedOut => Paths.login,
    AuthGate.ready => null,
  };
  if (parked != null) return path == parked ? null : parked;

  // AuthGate.ready is defined as "session present and profile loaded", so this is non-null.
  // Parking rather than asserting keeps a future change to the gate from crashing a shipped
  // APK on a state it has never seen.
  final user = ref.read(currentUserProvider).valueOrNull;
  if (user == null) return path == Paths.splash ? null : Paths.splash;

  if (path == Paths.splash || path == Paths.login) return Paths.homeFor(user);

  return switch (user.principal) {
    // A vendor seeing another vendor's job is a business-ending defect, so a partner principal
    // reaches exactly one subtree and nothing else — not even Settings.
    PrincipalClass.partner => Paths.within(path, Paths.partner) ? null : Paths.partner,
    PrincipalClass.customer => Paths.within(path, Paths.portal) ? null : Paths.portal,
    // The portal renders through `auth_customer()`, which is null for staff — an internal user
    // standing there would see a correct, permanent blank. Send them to work instead.
    PrincipalClass.internal => Paths.within(path, Paths.portal) ? Paths.dashboard : null,
  };
}

/// Where the splash hands off to once its gate settles on a destination.
String _landingFor(Ref ref, AuthGate gate) {
  if (gate != AuthGate.ready) return Paths.login;
  final user = ref.read(currentUserProvider).valueOrNull;
  return user == null ? Paths.login : Paths.homeFor(user);
}

/// The routes inside one shell branch.
///
/// The per-job work surfaces (CAD, QC, certification, shipping) live in the Jobs branch rather
/// than Production so that opening QC from a job detail does not move the highlight out from
/// under the operator.
List<RouteBase> _branchRoutes(NavArea area) => switch (area) {
      NavArea.dashboard => <RouteBase>[
          GoRoute(
            path: Paths.dashboard,
            name: RouteNames.dashboard,
            // The eight operational counters are a derived view over the 14-stage rail (D-002),
            // not a second status enum.
            builder: (context, state) => const RoleGate.area(
              NavArea.dashboard,
              child: DashboardScreen(),
            ),
          ),
        ],
      NavArea.production => <RouteBase>[
          GoRoute(
            path: Paths.production,
            name: RouteNames.production,
            // All eight columns (D-002). `ProductionBoardScreen`, not `ProductionBoard` — that
            // name belongs to the view aggregate in `data/repositories/dashboard_repository.dart`.
            builder: (context, state) => const RoleGate.area(
              NavArea.production,
              child: ProductionBoardScreen(),
            ),
          ),
        ],
      NavArea.jobs => <RouteBase>[
          GoRoute(
            path: Paths.jobs,
            name: RouteNames.jobs,
            // Fill in: lib/features/jobs/jobs_screen.dart
            //          -> JobsScreen(query: state.uri.queryParameters['q'])
            builder: (context, state) => RoleGate.area(
              NavArea.jobs,
              child: ComingSoon(
                area: 'Jobs',
                path: Paths.jobs,
                note: state.uri.queryParameters['q'] == null
                    ? null
                    : 'Searching for "${state.uri.queryParameters['q']}". The job list reads '
                        'the q parameter; the screen itself lands with the jobs feature.',
              ),
            ),
          ),
          GoRoute(
            path: '/jobs/:id',
            name: RouteNames.jobDetail,
            // Fill in: lib/features/jobs/job_detail_screen.dart -> JobDetailScreen(jobId: id)
            builder: (context, state) => RoleGate.area(
              NavArea.jobs,
              child: ComingSoon(
                area: 'Job Order',
                path: Paths.job(state.pathParameters['id'] ?? ''),
              ),
            ),
          ),
          GoRoute(
            path: '/cad/:revisionId',
            name: RouteNames.cad,
            // Fill in: lib/features/cad/cad_review_screen.dart -> CadReviewScreen(revisionId:)
            builder: (context, state) => RoleGate.custom(
              label: 'CAD Review',
              allow: AreaRoles.cad,
              child: ComingSoon(
                area: 'CAD Review',
                path: Paths.cad(state.pathParameters['revisionId'] ?? ''),
                note: 'D-011 rule 2: "Request Revisions" is blocked on an empty comment; '
                    '"Approve" is not. Rejection owes the designer a reason.',
              ),
            ),
          ),
          GoRoute(
            path: '/qc/:jobId',
            name: RouteNames.qc,
            // Fill in: lib/features/qc/qc_screen.dart -> QcScreen(jobId: jobId)
            builder: (context, state) => RoleGate.custom(
              label: 'Quality Control',
              allow: AreaRoles.qc,
              child: ComingSoon(
                area: 'Quality Control',
                path: Paths.qc(state.pathParameters['jobId'] ?? ''),
                note: 'D-011 rule 3: authorisation enables only at a full checklist — and '
                    'D-006 restores the FAIL path the mockup designed and made unreachable.',
              ),
            ),
          ),
          GoRoute(
            path: '/certification/:jobId',
            name: RouteNames.certification,
            // Fill in: lib/features/certification/certification_screen.dart
            builder: (context, state) => RoleGate.custom(
              label: 'Certification',
              allow: AreaRoles.logistics,
              child: ComingSoon(
                area: 'Certification',
                path: Paths.certification(state.pathParameters['jobId'] ?? ''),
              ),
            ),
          ),
          GoRoute(
            path: '/shipping/:jobId',
            name: RouteNames.shipping,
            // Fill in: lib/features/shipping/shipping_screen.dart
            builder: (context, state) => RoleGate.custom(
              label: 'Shipping',
              allow: AreaRoles.logistics,
              child: ComingSoon(
                area: 'Shipping',
                path: Paths.shipping(state.pathParameters['jobId'] ?? ''),
                note: 'Dispatch is refused by fn_dispatch_shipment while a security check is '
                    'open. The mockup only dimmed the button and left it pressable.',
              ),
            ),
          ),
        ],
      NavArea.partners => <RouteBase>[
          GoRoute(
            path: Paths.partner,
            name: RouteNames.partner,
            // A vendor sees only jobs with a stage assigned to them — scoped by partner_users in
            // RLS, not by a chip on the screen. The same screen is the internal vendor desk.
            builder: (context, state) => const RoleGate.area(
              NavArea.partners,
              child: PartnerQueueScreen(),
            ),
            routes: <RouteBase>[
              GoRoute(
                path: ':jobId',
                name: RouteNames.partnerJob,
                // D-011 rule 1: the caster cannot complete this stage without uploading a
                // casting photo, and the button ships disabled behind it.
                builder: (context, state) => RoleGate.area(
                  NavArea.partners,
                  child: CastingJobScreen(jobId: state.pathParameters['jobId'] ?? ''),
                ),
              ),
            ],
          ),
        ],
      NavArea.inventory => <RouteBase>[
          GoRoute(
            path: Paths.inventory,
            name: RouteNames.inventory,
            // Fill in: lib/features/inventory/inventory_screen.dart
            builder: (context, state) => const RoleGate.area(
              NavArea.inventory,
              child: ComingSoon(
                area: 'Inventory',
                path: Paths.inventory,
                note: 'Stone rows always show origin — Natural or Lab Grown. It survived in '
                    'exactly one of the 46 mockups and is never optional here.',
              ),
            ),
          ),
        ],
      NavArea.portal => <RouteBase>[
          GoRoute(
            path: Paths.portal,
            name: RouteNames.portal,
            // Not role-gated: the portal renders through `auth_customer()`, and the redirect above
            // already sends an internal principal to the dashboard rather than to a screen that
            // can only ever come back empty for them.
            builder: (context, state) => const PortalJobsScreen(),
            routes: <RouteBase>[
              GoRoute(
                path: ':jobId',
                name: RouteNames.portalJob,
                builder: (context, state) =>
                    PortalJobScreen(jobId: state.pathParameters['jobId'] ?? ''),
              ),
            ],
          ),
        ],
      NavArea.settings => <RouteBase>[
          GoRoute(
            path: Paths.settings,
            name: RouteNames.settings,
            // Fill in: lib/features/settings/settings_screen.dart -> const SettingsScreen()
            builder: (context, state) => const RoleGate.area(
              NavArea.settings,
              child: ComingSoon(area: 'Settings', path: Paths.settings),
            ),
          ),
        ],
    };

/// Bridges Riverpod's gate to go_router's `refreshListenable`, which is the only way the
/// redirect re-runs when someone signs in or out.
final class _RouterRefresh extends ChangeNotifier {
  void bump() => notifyListeners();
}

final class _UnknownRoute extends StatelessWidget {
  const _UnknownRoute({required this.location});

  final String location;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ErrorState(
            icon: Icons.wrong_location_outlined,
            title: 'That address does not exist',
            message: 'Nothing in DhanaOS answers to $location. Check the link, or start from '
                'the dashboard.',
            onRetry: () => context.go(Paths.splash),
            retryLabel: 'Go to the start',
          ),
        ),
      );
}
