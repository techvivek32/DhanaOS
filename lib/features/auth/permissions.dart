/// What the signed-in operator may do — read from `user_roles`, never from a UI flag.
///
/// This is a **presentation** check. RLS (0009_rls.sql) is the enforcement; a partner who
/// defeats everything here still cannot read another partner's job, because Postgres decides
/// that. What this buys is honesty: a disabled button with a reason beats an enabled button
/// that produces a server refusal the operator cannot interpret.
///
/// Three of these are irreversible and get their own named getters because they are the three
/// decisions the business cannot take back:
///
///   * [Permissions.canApproveDesign] — a CAD approval releases the design to production.
///   * [Permissions.canApprovePrice] — a price approval is what the customer is invoiced against.
///   * [Permissions.canAuthorizeQc] — a QC authorisation signs off a piece for dispatch.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';

part 'permissions.g.dart';

/// One gated action, with the roles that unlock it.
///
/// Every capability here also requires [PrincipalClass.internal]. That is not a detail: the
/// mockups let the vendor screen and the customer screen render internal controls, and the
/// first thing a partner account must not see is a QC authorisation button.
enum Capability {
  approveDesign(
    'Approve a CAD design',
    [UserRole.admin, UserRole.engineer, UserRole.productionManager],
  ),
  approvePrice(
    'Approve a price',
    [UserRole.admin, UserRole.engineer],
  ),
  authorizeQc(
    'Authorise QC',
    [UserRole.admin, UserRole.qcInspector],
  ),
  seeInventory(
    'Open the vault',
    [
      UserRole.admin,
      UserRole.inventoryKeeper,
      UserRole.productionManager,
      UserRole.engineer,
    ],
  ),
  editJob(
    'Edit a job',
    [
      UserRole.admin,
      UserRole.engineer,
      UserRole.productionManager,
      UserRole.cadDesigner,
    ],
  ),
  moveStock(
    'Move stock',
    [UserRole.admin, UserRole.inventoryKeeper, UserRole.productionManager],
  ),
  dispatch(
    'Dispatch a shipment',
    [UserRole.admin, UserRole.logistics],
  ),
  manageUsers(
    'Manage users and roles',
    [UserRole.admin],
  );

  const Capability(this.action, this.roles);

  /// Phrased as the thing being done, so a refusal reads as a sentence.
  final String action;

  /// Any one of these unlocks it.
  final List<UserRole> roles;

  /// What to tell someone who does not have it — convention 8: what went wrong, and how to fix
  /// it. Naming the role is the fix; "contact your administrator" is not.
  String get requirementLabel {
    final names = [for (final role in roles) role.label];
    if (names.length == 1) return names.single;
    return '${names.sublist(0, names.length - 1).join(', ')} or ${names.last}';
  }
}

/// A typed capability check over the session user.
final class Permissions {
  const Permissions(this.user);

  /// Null while the profile is loading, or when the account is not provisioned. Everything
  /// below is then false — an unknown operator gets nothing, never a default.
  final AppUser? user;

  bool get isSignedIn => user != null;
  bool get isInternal => user?.isInternal ?? false;
  bool get isPartner => user?.isPartner ?? false;
  bool get isCustomer => user?.isCustomer ?? false;
  bool get isAdmin => user?.isAdmin ?? false;

  /// The check everything else is built on.
  bool can(Capability capability) {
    final current = user;
    if (current == null) return false;
    if (!current.isInternal) return false;
    if (!current.isActive) return false;
    return current.hasAnyRole(capability.roles);
  }

  /// Why the action is unavailable, or null when it is available. Put this on the disabled
  /// button's tooltip or under it — never leave a dead control unexplained.
  String? blockReason(Capability capability) {
    final current = user;
    if (current == null) return 'Sign in to ${capability.action.toLowerCase()}.';
    if (!current.isActive) {
      return 'This account is deactivated. An admin has to re-enable it.';
    }
    if (!current.isInternal) {
      return '${capability.action} is an internal action. '
          'Your account is a ${current.principal.wire} account.';
    }
    if (!current.hasAnyRole(capability.roles)) {
      return 'Only ${capability.requirementLabel} can ${capability.action.toLowerCase()}. '
          'Ask an admin to add the role.';
    }
    return null;
  }

  // The three irreversible ones, named so a call site reads as the decision it is making.

  /// Releases a CAD design to production.
  bool get canApproveDesign => can(Capability.approveDesign);

  /// Fixes what the customer is invoiced against.
  bool get canApprovePrice => can(Capability.approvePrice);

  /// Signs a piece off for dispatch. D-011 rule 3 additionally requires a full checklist, and
  /// that rule lives in `fn_complete_stage` — this getter only decides who may press it.
  bool get canAuthorizeQc => can(Capability.authorizeQc);

  /// The vault holds stone valuations and customer-supplied custody records. Never a partner,
  /// never a customer.
  bool get canSeeInventory => can(Capability.seeInventory);

  bool get canEditJob => can(Capability.editJob);
  bool get canMoveStock => can(Capability.moveStock);
  bool get canDispatch => can(Capability.dispatch);
  bool get canManageUsers => can(Capability.manageUsers);

  /// A partner may close its own assigned stage. Which stage, and whether the evidence is
  /// there, is `fn_complete_stage`'s call (D-011 rule 1).
  bool get canCompleteAssignedStage => isPartner || canEditJob;
}

/// Rebuilds whenever the session user does, so a role granted mid-shift takes effect on the
/// next profile refresh rather than on the next app restart.
@Riverpod(keepAlive: true)
Permissions permissions(Ref ref) =>
    Permissions(ref.watch(currentUserProvider).valueOrNull);

/// Sugar for a single gate in a widget: `ref.watch(canProvider(Capability.authorizeQc))`.
@riverpod
bool can(Ref ref, Capability capability) =>
    ref.watch(permissionsProvider).can(capability);
