/// The app frame: one responsive shell, the global top bar, and the two states a route can be
/// in before its screen exists.
///
/// Import this one file:
///
/// ```dart
/// import 'package:dhanaos/shared/shell/shell.dart';
/// ```
///
/// Routing itself lives in `package:dhanaos/core/router.dart` — that is where `Paths`,
/// `RouteNames` and the session provider are.
library;

export 'app_shell.dart' show AppShell, AreaRoles, NavArea;
export 'coming_soon.dart' show ComingSoon;
export 'no_access.dart' show NoAccess;
export 'top_bar.dart' show OpenAction, TopBar, openActionsProvider;
