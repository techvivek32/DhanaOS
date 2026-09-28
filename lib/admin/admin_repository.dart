/// The admin panel's reads and writes.
///
/// Reads are ordinary PostgREST selects scoped by RLS: a workspace admin sees their own org, a
/// super admin sees every org read-only (0014 `_platform_read` policies). Every write that
/// touches an account goes through a `fn_admin_*` / `fn_platform_*` RPC, because accounts live in
/// `auth.users`, which the client cannot reach — and because the rules (last admin, own admin
/// role, other workspaces) are enforced there.
library;

import 'dart:math';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/data/repositories/customer_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';

part 'admin_repository.g.dart';

/// One tenant as the platform console lists it (`v_platform_tenants`).
final class TenantSummary {
  const TenantSummary({
    required this.id,
    required this.name,
    required this.isActive,
    required this.createdAt,
    required this.activeMembers,
    required this.admins,
    required this.customers,
    required this.partners,
    required this.openJobs,
    required this.totalJobs,
    this.legalName,
    this.gstin,
    this.baseCurrency = 'INR',
    this.suspendedAt,
    this.suspendedReason,
    this.lastActivity,
  });

  factory TenantSummary.fromRow(Map<String, dynamic> row) => TenantSummary(
    id: row['id'] as String,
    name: row['name'] as String,
    legalName: row['legal_name'] as String?,
    gstin: row['gstin'] as String?,
    baseCurrency: (row['base_currency'] as String?)?.trim() ?? 'INR',
    isActive: row['is_active'] as bool? ?? true,
    suspendedAt: _instant(row['suspended_at']),
    suspendedReason: row['suspended_reason'] as String?,
    createdAt: _instant(row['created_at'])!,
    activeMembers: row['active_members'] as int? ?? 0,
    admins: row['admins'] as int? ?? 0,
    customers: row['customers'] as int? ?? 0,
    partners: row['partners'] as int? ?? 0,
    openJobs: row['open_jobs'] as int? ?? 0,
    totalJobs: row['total_jobs'] as int? ?? 0,
    lastActivity: _instant(row['last_activity']),
  );

  final String id;
  final String name;
  final String? legalName;
  final String? gstin;
  final String baseCurrency;
  final bool isActive;
  final DateTime? suspendedAt;
  final String? suspendedReason;
  final DateTime createdAt;
  final int activeMembers;
  final int admins;
  final int customers;
  final int partners;
  final int openJobs;
  final int totalJobs;
  final DateTime? lastActivity;
}

DateTime? _instant(Object? value) => value is String ? DateTime.parse(value).toUtc() : null;

final class AdminRepository {
  const AdminRepository(this._client);

  final SupabaseClient _client;

  // ------------------------------------------------------------ members

  /// Everyone in a workspace — staff, partner logins and customer logins — alphabetical. RLS
  /// limits a workspace admin to their own org; [orgId] narrows a super admin to one tenant.
  Future<List<AppUser>> members({String? orgId}) async {
    final rows = await guard(() {
      final base = _client.from('app_users').select(userSelect);
      final scoped = orgId == null ? base : base.eq('org_id', orgId);
      return scoped.order('full_name', ascending: true);
    });
    return [for (final row in rows) appUserFromRow(row)];
  }

  Future<AppUser> member(String userId) async {
    final row = await guard(
      () => _client.from('app_users').select(userSelect).eq('id', userId).single(),
    );
    return appUserFromRow(row);
  }

  Future<String> createMember({
    required String email,
    required String fullName,
    required String tempPassword,
    PrincipalClass principal = PrincipalClass.internal,
    Set<UserRole> roles = const {},
    String? title,
    String? phone,
    String? customerId,
    String? partnerId,
    String? orgId,
  }) async {
    final id = await guard(
      () => _client.rpc<dynamic>(
        'fn_admin_create_user',
        params: {
          'p_email': email.trim(),
          'p_full_name': fullName.trim(),
          'p_temp_password': tempPassword,
          // Convention 6: enums cross as their Postgres values.
          'p_principal': principal.wire,
          'p_roles': [for (final r in roles) r.wire],
          'p_title': title,
          'p_phone': phone,
          'p_customer': customerId,
          'p_partner': partnerId,
          'p_org': orgId,
        },
      ),
    );
    return id as String;
  }

  Future<void> updateMember(
    String userId, {
    required String fullName,
    String? title,
    String? phone,
    Set<UserRole>? roles,
  }) => guard(
    () => _client.rpc<dynamic>(
      'fn_admin_update_member',
      params: {
        'p_user': userId,
        'p_full_name': fullName.trim(),
        'p_title': title,
        'p_phone': phone,
        'p_roles': roles == null ? null : [for (final r in roles) r.wire],
      },
    ),
  );

  Future<void> setMemberActive(String userId, {required bool active}) => guard(
    () => _client.rpc<dynamic>(
      'fn_admin_set_member_active',
      params: {'p_user': userId, 'p_active': active},
    ),
  );

  Future<void> resetPassword(String userId, String tempPassword) => guard(
    () => _client.rpc<dynamic>(
      'fn_admin_reset_password',
      params: {'p_user': userId, 'p_temp_password': tempPassword},
    ),
  );

  // ------------------------------------------------------------ workspace

  Future<Org> org(String orgId) async {
    final row = await guard(() => _client.from('orgs').select().eq('id', orgId).single());
    return Org.fromJson(row);
  }

  /// The profile an invoice prints (D-004). The job-code counter is not writable (0014).
  Future<Org> updateOrg(
    String orgId, {
    required String name,
    String? legalName,
    String? gstin,
    String? pan,
    required Map<String, dynamic> address,
    required String baseCurrency,
  }) async {
    final row = await guard(
      () => _client
          .from('orgs')
          .update({
            'name': name.trim(),
            'legal_name': _blank(legalName),
            'gstin': _blank(gstin)?.toUpperCase(),
            'pan': _blank(pan)?.toUpperCase(),
            'address': address,
            'base_currency': baseCurrency,
          })
          .eq('id', orgId)
          .select()
          .single(),
    );
    return Org.fromJson(row);
  }

  /// Newest first: the top row per metal and purity is the rate a quote locks against.
  Future<List<MetalRate>> rates({String? orgId}) async {
    final rows = await guard(() {
      final base = _client.from('metal_rates').select();
      final scoped = orgId == null ? base : base.eq('org_id', orgId);
      return scoped.order('effective_at', ascending: false).limit(200);
    });
    return [for (final row in rows) MetalRate.fromJson(row)];
  }

  Future<void> addRate({
    required String orgId,
    required BaseMetal metal,
    MetalPurity? purity,
    required int ratePerGMinor,
    required String currency,
    String? source,
  }) => guard(
    () => _client.from('metal_rates').insert({
      'org_id': orgId,
      'base_metal': metal.wire,
      'purity': purity?.wire,
      'rate_per_g': ratePerGMinor,
      'currency': currency,
      'source': _blank(source) ?? 'manual',
    }),
  );

  Future<List<Resource>> resources({String? orgId}) async {
    final rows = await guard(() {
      final base = _client.from('resources').select();
      final scoped = orgId == null ? base : base.eq('org_id', orgId);
      return scoped.order('code', ascending: true);
    });
    return [for (final row in rows) Resource.fromJson(row)];
  }

  Future<void> saveResource({
    String? id,
    required String orgId,
    required String code,
    required String label,
    LifecycleStage? stage,
    bool isActive = true,
  }) {
    final payload = <String, dynamic>{
      'org_id': orgId,
      'code': code.trim().toUpperCase(),
      'label': label.trim(),
      'stage': stage?.wire,
      'is_active': isActive,
    };
    return guard(
      () => id == null
          ? _client.from('resources').insert(payload)
          : _client.from('resources').update(payload).eq('id', id),
    );
  }

  // ------------------------------------------------------------ platform

  Future<List<TenantSummary>> tenants() async {
    final rows = await guard(
      () => _client.from('v_platform_tenants').select().order('name', ascending: true),
    );
    return [for (final row in rows) TenantSummary.fromRow(row)];
  }

  Future<TenantSummary> tenant(String orgId) async {
    final row = await guard(
      () => _client.from('v_platform_tenants').select().eq('id', orgId).single(),
    );
    return TenantSummary.fromRow(row);
  }

  Future<String> createTenant({
    required String name,
    String? legalName,
    String? gstin,
    required String baseCurrency,
    required Map<String, dynamic> address,
    required String adminName,
    required String adminEmail,
    required String adminPassword,
  }) async {
    final id = await guard(
      () => _client.rpc<dynamic>(
        'fn_platform_create_org',
        params: {
          'p_name': name.trim(),
          'p_legal_name': _blank(legalName),
          'p_gstin': _blank(gstin),
          'p_base_currency': baseCurrency,
          'p_admin_email': adminEmail.trim(),
          'p_admin_name': adminName.trim(),
          'p_admin_password': adminPassword,
          'p_address': address,
        },
      ),
    );
    return id as String;
  }

  Future<void> setTenantActive(String orgId, {required bool active, String? reason}) => guard(
    () => _client.rpc<dynamic>(
      'fn_platform_set_org_active',
      params: {'p_org': orgId, 'p_active': active, 'p_reason': _blank(reason)},
    ),
  );

  Future<List<Customer>> customersOf(String orgId) async {
    final rows = await guard(
      () => _client.from('customers').select().eq('org_id', orgId).order('name'),
    );
    return [for (final row in rows) Customer.fromJson(row)];
  }

  Future<List<Partner>> partnersOf(String orgId) async {
    final rows = await guard(
      () => _client.from('partners').select().eq('org_id', orgId).order('name'),
    );
    return [for (final row in rows) Partner.fromJson(row)];
  }

  /// A tenant's jobs, newest first, for the super admin's read-only view.
  Future<List<Map<String, dynamic>>> jobsOf(String orgId) => guard(
    () => _client
        .from('v_job_list')
        .select(
          'id, display_code, title, status, current_stage, customer_name, '
          'requested_delivery, quote_total, currency',
        )
        .eq('org_id', orgId)
        .order('display_code', ascending: false)
        .limit(200),
  );
}

String? _blank(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// A temporary password the admin reads out or pastes to the new member: twelve characters from
/// an alphabet without look-alikes (no 0/O, 1/l/I), so it survives being read over the phone.
String generateTempPassword() {
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  final random = Random.secure();
  return List.generate(12, (_) => alphabet[random.nextInt(alphabet.length)]).join();
}

// ================================================================= providers

@Riverpod(keepAlive: true)
AdminRepository adminRepository(Ref ref) => AdminRepository(ref.watch(supabaseProvider));

@riverpod
Future<List<AppUser>> workspaceMembers(Ref ref) => ref.watch(adminRepositoryProvider).members();

@riverpod
Future<AppUser> workspaceMember(Ref ref, String userId) =>
    ref.watch(adminRepositoryProvider).member(userId);

@riverpod
Future<Org> workspaceOrg(Ref ref, String orgId) => ref.watch(adminRepositoryProvider).org(orgId);

@riverpod
Future<List<Customer>> workspaceCustomers(Ref ref) =>
    ref.watch(customerRepositoryProvider).listCustomers();

@riverpod
Future<List<Partner>> workspacePartners(Ref ref) =>
    ref.watch(customerRepositoryProvider).listPartners(activeOnly: false);

@riverpod
Future<List<MetalRate>> workspaceRates(Ref ref) => ref.watch(adminRepositoryProvider).rates();

@riverpod
Future<List<Resource>> workspaceResources(Ref ref) =>
    ref.watch(adminRepositoryProvider).resources();

@riverpod
Future<List<TenantSummary>> tenants(Ref ref) => ref.watch(adminRepositoryProvider).tenants();

@riverpod
Future<TenantSummary> tenant(Ref ref, String orgId) =>
    ref.watch(adminRepositoryProvider).tenant(orgId);

@riverpod
Future<List<AppUser>> tenantMembers(Ref ref, String orgId) =>
    ref.watch(adminRepositoryProvider).members(orgId: orgId);

@riverpod
Future<List<Customer>> tenantCustomers(Ref ref, String orgId) =>
    ref.watch(adminRepositoryProvider).customersOf(orgId);

@riverpod
Future<List<Partner>> tenantPartners(Ref ref, String orgId) =>
    ref.watch(adminRepositoryProvider).partnersOf(orgId);

@riverpod
Future<List<Map<String, dynamic>>> tenantJobs(Ref ref, String orgId) =>
    ref.watch(adminRepositoryProvider).jobsOf(orgId);
