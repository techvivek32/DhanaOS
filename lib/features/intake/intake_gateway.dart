/// Two reads the intake wizard needs that no repository owns yet: the workshop's own record, and
/// the people a CAD stage can be handed to.
///
/// The org row carries the GSTIN that decides CGST+SGST versus IGST on step 7's tax preview, and
/// the `job_seq` counter that lets step 10 show the operator the number their job is about to be
/// given. Neither is worth a repository of its own, and both are read-only here.
///
/// D-008 is respected exactly as the RLS writes it. `users_read` lets an internal principal list
/// the people in their own org; `roles_read` shows `user_roles` only to admins. So a non-admin
/// asking for CAD designers gets the org's people with no role labels rather than an empty list —
/// and [DesignerDirectory.rolesVisible] says which of the two happened, so the picker can tell the
/// truth instead of implying the workshop has no designers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'intake_gateway.g.dart';

/// Who a CAD stage can go to, split by whether the database would confirm the role.
final class DesignerDirectory {
  const DesignerDirectory({
    required this.designers,
    required this.others,
    required this.rolesVisible,
  });

  static const empty = DesignerDirectory(
    designers: <AppUser>[],
    others: <AppUser>[],
    rolesVisible: false,
  );

  /// People who hold `cad_designer`.
  final List<AppUser> designers;

  /// Everyone else internal and active — an engineer often draws the first revision themselves.
  final List<AppUser> others;

  /// False when `roles_read` withheld `user_roles` from this operator, which is the normal case
  /// for anyone who is not an admin.
  final bool rolesVisible;

  bool get isEmpty => designers.isEmpty && others.isEmpty;

  /// What to put above the list, so an operator understands why a colleague is or is not in it.
  String get note => rolesVisible
      ? 'Anyone holding the CAD Designer role. The rest of the team is listed below them.'
      : 'Role labels are only visible to admins, so everyone internal is listed. '
          'Pick the person who is actually drawing this.';
}

final class IntakeGateway {
  const IntakeGateway(this._client, this._identity);

  final SupabaseClient _client;
  final RepoIdentity _identity;

  /// The workshop. Null while the session is still resolving, which the wizard treats as
  /// "no GSTIN known yet" rather than as an error — a draft can be written without one.
  Future<Org?> org() async {
    final orgId = _identity.orgId;
    if (orgId == null) return null;
    final row = await guardOrNull(
      () => _client.from('orgs').select().eq('id', orgId).maybeSingle(),
    );
    return row == null ? null : Org.fromJson(row);
  }

  Future<DesignerDirectory> cadDesigners() async {
    final orgId = _identity.orgId;
    if (orgId == null) return DesignerDirectory.empty;
    final rows = await guard(
      () => _client
          .from('app_users')
          .select('*, user_roles(role)')
          .eq('org_id', orgId)
          // Convention 6: the enum crosses the wire as its Postgres value.
          .eq('principal', PrincipalClass.internal.wire)
          .eq('is_active', true)
          .order('full_name', ascending: true),
    );

    final everyone = [for (final row in rows) AppUser.fromJson(_shape(row))];
    final rolesVisible = everyone.any((u) => u.roleWires.isNotEmpty);
    return DesignerDirectory(
      designers: [
        for (final u in everyone)
          if (u.hasRole(UserRole.cadDesigner)) u,
      ],
      others: [
        for (final u in everyone)
          if (!u.hasRole(UserRole.cadDesigner)) u,
      ],
      rolesVisible: rolesVisible,
    );
  }

  /// One person, for rendering "Assigned to …" after the stage is handed over.
  Future<AppUser?> user(String userId) async {
    final row = await guardOrNull(
      () => _client
          .from('app_users')
          .select('*, user_roles(role)')
          .eq('id', userId)
          .maybeSingle(),
    );
    return row == null ? null : AppUser.fromJson(_shape(row));
  }

  /// Flattens the embedded `user_roles` rows into the `roles` list `AppUser.fromJson` expects.
  /// An operator without `roles_read` gets an empty list here, never a crash.
  static Map<String, dynamic> _shape(Map<String, dynamic> row) {
    final shaped = Map<String, dynamic>.from(row);
    final roles = <String>[];
    final embedded = row['user_roles'];
    if (embedded is List) {
      for (final entry in embedded) {
        if (entry is Map && entry['role'] is String) roles.add(entry['role'] as String);
      }
    }
    shaped
      ..remove('user_roles')
      ..['roles'] = roles;
    return shaped;
  }
}

@Riverpod(keepAlive: true)
IntakeGateway intakeGateway(Ref ref) => IntakeGateway(
      ref.watch(supabaseProvider),
      ref.watch(repoIdentityProvider),
    );

/// The CAD designer picker on step 11.
@riverpod
Future<DesignerDirectory> cadDesignerDirectory(Ref ref) =>
    ref.watch(intakeGatewayProvider).cadDesigners();
