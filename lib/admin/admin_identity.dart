/// Who is using the admin panel, and whether they may.
///
/// Two kinds of administrator reach it (0014): a platform super admin, who belongs to no
/// workspace and is found in `platform_admins`; and a workspace admin, an internal member of one
/// org holding the `admin` role. Everyone else is told to use the DhanaOS app. None of this is
/// the access decision — RLS and the `fn_admin_*` / `fn_platform_*` RPCs are — it only decides
/// which console to draw.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';

part 'admin_identity.g.dart';

sealed class AdminIdentity {
  const AdminIdentity();
}

/// Operates the platform: every tenant, read-only below the tenant level.
final class PlatformAdmin extends AdminIdentity {
  const PlatformAdmin({required this.userId, required this.fullName, this.email});

  final String userId;
  final String fullName;
  final String? email;
}

/// Administers one workspace.
final class WorkspaceAdmin extends AdminIdentity {
  const WorkspaceAdmin(this.user);

  final AppUser user;
}

/// Signed in, but holds no administrative role.
final class NotAnAdmin extends AdminIdentity {
  const NotAnAdmin(this.user);

  final AppUser? user;
}

@Riverpod(keepAlive: true)
Future<AdminIdentity?> adminIdentity(Ref ref) async {
  final session = ref.watch(currentSessionProvider);
  if (session == null) return null;

  final platform = await guardOrNull(
    () => ref
        .watch(supabaseProvider)
        .from('platform_admins')
        .select('full_name, email')
        .eq('user_id', session.user.id)
        .maybeSingle(),
  );
  if (platform != null) {
    return PlatformAdmin(
      userId: session.user.id,
      fullName: platform['full_name'] as String,
      email: platform['email'] as String?,
    );
  }

  final user = await ref.watch(currentUserProvider.future);
  if (user != null && user.isInternal && user.isAdmin) return WorkspaceAdmin(user);
  return NotAnAdmin(user);
}

/// What the panel shows right now. The router parks every state but the two consoles.
enum AdminGate {
  booting,
  unconfigured,
  bootFailed,
  signedOut,

  /// Signed in without an administrative role.
  notAdmin,

  /// The workspace is suspended, or this admin was deactivated.
  suspended,
  deactivated,

  /// Signed in on a temporary password.
  mustChangePassword,

  /// Could not tell who this is — offline, or the identity read failed.
  failed,

  platform,
  workspace,
}

@Riverpod(keepAlive: true)
AdminGate adminGate(Ref ref) {
  final boot = ref.watch(bootstrapProvider).value;
  if (boot == null) return AdminGate.booting;
  if (boot is BootstrapUnconfigured) return AdminGate.unconfigured;
  if (boot is BootstrapFailed) return AdminGate.bootFailed;
  if (ref.watch(currentSessionProvider) == null) return AdminGate.signedOut;

  return switch (ref.watch(adminIdentityProvider)) {
    AsyncData(value: PlatformAdmin()) => AdminGate.platform,
    // The workspace gate already knows suspension, deactivation and the temporary password.
    AsyncData(value: WorkspaceAdmin()) => switch (ref.watch(authGateProvider)) {
      AuthGate.suspended => AdminGate.suspended,
      AuthGate.deactivated => AdminGate.deactivated,
      AuthGate.mustChangePassword => AdminGate.mustChangePassword,
      AuthGate.ready => AdminGate.workspace,
      AuthGate.profileBlocked => AdminGate.failed,
      _ => AdminGate.booting,
    },
    AsyncData(value: NotAnAdmin(user: final AppUser user)) when !user.orgActive =>
      AdminGate.suspended,
    AsyncData() => AdminGate.notAdmin,
    AsyncError() => AdminGate.failed,
    _ => AdminGate.booting,
  };
}
