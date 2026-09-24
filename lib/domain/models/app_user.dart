/// `app_users` + `user_roles` — the session identity.
///
/// D-008: all 46 mockups hardcoded one identity, "Ravi S. — Manufacturing Engineer", and it
/// leaked onto the external vendor's screen and the customer's approval screen. Nothing here
/// grants access — RLS does that — but every surface renders *this* user, never a literal.
library;

import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'app_user.freezed.dart';
part 'app_user.g.dart';

@freezed
class AppUser with _$AppUser {
  const AppUser._();

  const factory AppUser({
    required String id,
    @JsonKey(name: 'org_id') required String orgId,
    @PrincipalClassConverter() @Default(PrincipalClass.internal) PrincipalClass principal,
    @JsonKey(name: 'full_name') required String fullName,

    /// "Manufacturing Engineer" — a free-text job title, not a permission.
    String? title,

    /// "JD", "PR-02" — what a stage completion is credited to on the timeline.
    String? initials,
    String? email,
    String? phone,
    @JsonKey(name: 'avatar_path') String? avatarPath,
    @JsonKey(name: 'is_active') @Default(true) bool isActive,
    @JsonKey(name: 'created_at') required DateTime createdAt,

    /// Wire values from the `user_roles` join. Held as strings because Postgres returns them
    /// as a nested array of rows; `roles` parses them through `UserRole.parse` (convention 6).
    /// Never sent back — role grants are written to `user_roles`, not to `app_users`.
    @JsonKey(name: 'roles', includeToJson: false) @Default(<String>[]) List<String> roleWires,

    /// Set when this user is a retailer's staff (`customer_users`).
    @JsonKey(name: 'customer_id', includeToJson: false) String? customerId,

    /// Set when this user is a vendor's staff (`partner_users`). D-008: this — not a
    /// decorative "Assigned to Me" chip — is what scopes the partner queue.
    @JsonKey(name: 'partner_id', includeToJson: false) String? partnerId,
  }) = _AppUser;

  factory AppUser.fromJson(Map<String, dynamic> json) => _$AppUserFromJson(json);

  /// D-008: a user may hold several roles, so permission checks read the set, never a flag.
  Set<UserRole> get roles {
    final out = <UserRole>{};
    for (final w in roleWires) {
      final role = UserRole.parse(w);
      if (role != null) out.add(role);
    }
    return out;
  }

  bool hasRole(UserRole role) => roles.contains(role);

  bool hasAnyRole(Iterable<UserRole> any) {
    final held = roles;
    return any.any(held.contains);
  }

  bool get isInternal => principal == PrincipalClass.internal;
  bool get isPartner => principal == PrincipalClass.partner;
  bool get isCustomer => principal == PrincipalClass.customer;
  bool get isAdmin => hasRole(UserRole.admin);

  /// The three irreversible actions. D-008 requires these to read from `user_roles`; RLS
  /// enforces the same thing server-side, so a UI bypass buys nothing.
  bool get canApproveDesign =>
      hasAnyRole(const [UserRole.admin, UserRole.engineer, UserRole.productionManager]);

  bool get canApprovePrice => hasAnyRole(const [UserRole.admin, UserRole.engineer]);

  bool get canAuthorizeQc => hasAnyRole(const [UserRole.admin, UserRole.qcInspector]);

  bool get canMoveStock =>
      hasAnyRole(const [UserRole.admin, UserRole.inventoryKeeper, UserRole.productionManager]);

  bool get canDispatch => hasAnyRole(const [UserRole.admin, UserRole.logistics]);

  /// "Ravi S." — the initials chip falls back to the name when no code was assigned.
  String get displayInitials {
    final given = initials?.trim();
    if (given != null && given.isNotEmpty) return given;
    final parts = fullName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  /// "Ravi S. — Manufacturing Engineer". Prefers the stored title, falls back to the primary
  /// role's label so the strip is never blank.
  String get subtitle {
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    final held = roles;
    for (final r in UserRole.values) {
      if (held.contains(r)) return r.label;
    }
    return principal.wire;
  }
}
