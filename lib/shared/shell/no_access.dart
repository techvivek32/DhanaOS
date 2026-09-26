/// What an operator sees when they reach an area their roles do not open.
///
/// D-008 is enforced in Postgres — RLS is the authority and a UI bypass buys nothing. This
/// screen exists because a silent bounce back to the dashboard teaches an operator nothing:
/// the fix is almost always "ask an admin for a role", and that sentence has to appear
/// somewhere. The URL is kept, so a colleague with the right role can open the same link.
///
/// The neighbouring states — signed in with no `app_users` row, a refused profile read, the
/// first frame while Supabase starts — are *not* here. They belong to `AuthGate` and are
/// rendered by `features/auth/splash_screen.dart`, which is the one screen that knows the
/// difference between them.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

final class NoAccess extends StatelessWidget {
  const NoAccess({
    super.key,
    required this.area,
    required this.needs,
    this.standalone = false,
    this.onBack,
  });

  /// The area that was refused — "Inventory", "Quality Control".
  final String area;

  /// Any one of these roles opens it. Admin always passes and is therefore never listed.
  final List<UserRole> needs;

  final bool standalone;

  /// Where "Go back" leads. Omitted when the caller has nowhere sensible to send them.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final roleNames = needs.map((r) => r.label).join(', ');

    final body = ErrorState(
      icon: Icons.lock_outline_rounded,
      title: '$area is not open to your account',
      // Convention 8: name the role, because naming it is the fix. "Contact your
      // administrator" leaves the operator with nothing to say when they do.
      message: needs.isEmpty
          ? 'This area is for internal staff. Ask an admin to check how your account is set up.'
          : 'Opening $area needs one of these roles: $roleNames. Ask an admin to add one to '
              'your account, then sign out and back in.',
      onRetry: onBack,
      retryLabel: 'Go back',
    );

    if (!standalone) return body;
    return Scaffold(appBar: AppBar(title: Text(area)), body: SafeArea(child: body));
  }
}
