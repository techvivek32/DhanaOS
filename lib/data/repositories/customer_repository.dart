/// `customers` and `partners` — the retailers the workshop manufactures for, and the casters, gem
/// labs, stone suppliers, couriers and hubs it works with.
///
/// Two decisions shape this file.
///
/// **D-004 — GSTIN is not an optional note.** The manufacturer is an Indian entity, so the
/// customer's GSTIN decides place of supply and therefore IGST versus CGST + SGST on every
/// invoice. A GSTIN is validated here when one is given, because a malformed number is discovered
/// at invoicing time otherwise — which is the worst moment to discover it.
///
/// **Deleting a counterparty destroys history.** `jobs.customer_id` is `on delete restrict`, so
/// Postgres already refuses a customer with jobs; this refuses first with a sentence that says
/// what to do instead. `job_stages.assigned_partner` is `on delete set null`, which is worse — a
/// delete would succeed and quietly erase which foundry cast a piece. So a partner with any stage
/// history cannot be deleted at all, only deactivated, and [setPartnerActive] is the supported
/// path.
///
/// Scoping is not decided here. RLS restricts both tables to the caller's org and to internal
/// principals (D-008); a customer principal reads only its own row.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'customer_repository.g.dart';

/// `27ABCDE1234F1Z5` — two-digit state code, PAN, entity number, `Z`, checksum. The state code is
/// what `Customer.isInterstateFrom` compares, which is why the shape matters and not just the
/// length.
final _gstinShape = RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$');

final class CustomerRepository {
  const CustomerRepository(this._client, this._identity);

  final SupabaseClient _client;
  final RepoIdentity _identity;

  // ================================================================ customers

  /// Retailers, alphabetical. [search] matches name, code and contact.
  Future<List<Customer>> listCustomers({String? search, int limit = 200, int offset = 0}) async {
    final rows = await guard(() {
      final base = _client.from('customers').select();
      final term = _searchTerm(search);
      final filtered = term == null
          ? base
          : base.or('name.ilike.%$term%,code.ilike.%$term%,contact_name.ilike.%$term%');
      return filtered.order('name', ascending: true).range(offset, offset + limit - 1);
    });
    return [for (final row in rows) Customer.fromJson(row)];
  }

  Future<Customer> getCustomer(String customerId) async {
    final customer = await findCustomer(customerId);
    return customer ??
        (throw RecordNotFound(
          message: 'That customer is not on file, or is not yours to see.',
          detail: 'customers.id=$customerId',
          code: 'PGRST116',
        ));
  }

  Future<Customer?> findCustomer(String customerId) async {
    final row = await guardOrNull(
      () => _client.from('customers').select().eq('id', customerId).maybeSingle(),
    );
    return row == null ? null : Customer.fromJson(row);
  }

  /// Add a retailer.
  ///
  /// [currency] defaults to INR (D-004), and a retailer may legitimately be billed in another —
  /// which is why `customers.currency` exists rather than every amount being assumed to be the
  /// org's base.
  Future<Customer> createCustomer({
    required String name,
    String? code,
    String? contactName,
    String? email,
    String? phone,
    String? gstin,
    Map<String, dynamic> address = const {},
    String? paymentTerms,
    String currency = 'INR',
    String? notes,
  }) async {
    final orgId = _identity.requireOrgId();
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw const MissingRequiredField(
        message: 'Enter the retailer\'s name.',
        code: 'customer_name_empty',
      );
    }
    final number = _normaliseGstin(gstin);

    final row = await guard(
      () => _client
          .from('customers')
          .insert({
            'org_id': orgId,
            'name': trimmedName,
            'code': _blankToNull(code)?.toUpperCase(),
            'contact_name': _blankToNull(contactName),
            'email': _blankToNull(email)?.toLowerCase(),
            'phone': _blankToNull(phone),
            'gstin': number,
            'address': address,
            'payment_terms': _blankToNull(paymentTerms),
            'currency': currency,
            'notes': _blankToNull(notes),
          })
          .select()
          .single(),
    );
    return Customer.fromJson(row);
  }

  Future<Customer> updateCustomer(
    String customerId, {
    Opt<String>? name,
    Opt<String>? code,
    Opt<String>? contactName,
    Opt<String>? email,
    Opt<String>? phone,
    Opt<String>? gstin,
    Opt<Map<String, dynamic>>? address,
    Opt<String>? paymentTerms,
    Opt<String>? currency,
    Opt<String>? notes,
  }) async {
    final payload = <String, Object?>{};
    writeOpt(payload, 'name', name, (v) => v.trim());
    writeOpt(payload, 'code', code, (v) => v.trim().toUpperCase());
    writeOpt(payload, 'contact_name', contactName, (v) => v.trim());
    writeOpt(payload, 'email', email, (v) => v.trim().toLowerCase());
    writeOpt(payload, 'phone', phone, (v) => v.trim());
    writeOpt(payload, 'address', address);
    writeOpt(payload, 'payment_terms', paymentTerms, (v) => v.trim());
    writeOpt(payload, 'currency', currency);
    writeOpt(payload, 'notes', notes, (v) => v.trim());

    if (gstin != null) {
      // Clearing a GSTIN is allowed — an unregistered retailer is a real customer. A malformed one
      // is not.
      payload['gstin'] = _normaliseGstin(gstin.value);
    }

    if (payload.isEmpty) return getCustomer(customerId);

    final row = await guard(
      () => _client.from('customers').update(payload).eq('id', customerId).select().single(),
    );
    return Customer.fromJson(row);
  }

  /// Delete a retailer that has never been used.
  ///
  /// `jobs.customer_id` is `on delete restrict`, so Postgres would refuse this anyway — but as a
  /// `23503` it arrives as "a linked record is missing", which is the wrong sentence entirely.
  /// Counting first lets the refusal say what is actually in the way.
  Future<void> deleteCustomer(String customerId) async {
    final jobs = await countJobsFor(customerId);
    if (jobs > 0) {
      throw InvalidReference(
        message: 'This retailer has $jobs job${jobs == 1 ? '' : 's'} on file and cannot be '
            'deleted. Their history is part of those jobs.',
        detail: 'jobs.customer_id references customers.id with on delete restrict',
        code: 'customer_in_use',
      );
    }
    await guard(() => _client.from('customers').delete().eq('id', customerId));
  }

  Future<int> countJobsFor(String customerId) async {
    final rows = await guard(
      () => _client.from('jobs').select('id').eq('customer_id', customerId),
    );
    return rows.length;
  }

  // ================================================================ partners

  /// Vendors, labs, suppliers and couriers. Inactive ones are hidden unless asked for, because a
  /// picker that offers a foundry you have stopped using is how a job goes to the wrong place.
  Future<List<Partner>> listPartners({
    PartnerKind? kind,
    bool activeOnly = true,
    String? search,
    int limit = 200,
    int offset = 0,
  }) async {
    final rows = await guard(() {
      var query = _client.from('partners').select();
      if (kind != null) query = query.eq('kind', kind.wire);
      if (activeOnly) query = query.eq('is_active', true);
      final term = _searchTerm(search);
      if (term != null) {
        query = query.or('name.ilike.%$term%,contact_name.ilike.%$term%');
      }
      return query
          .order('kind', ascending: true)
          .order('name', ascending: true)
          .range(offset, offset + limit - 1);
    });
    return [for (final row in rows) Partner.fromJson(row)];
  }

  /// The partners that can actually take a given rail stage.
  ///
  /// D-002: only casting and certification leave the building, so every other stage returns an
  /// empty list rather than the whole vendor book. This is what an assignment picker reads, and it
  /// is why `JobRepository.assignStage` can refuse a courier on a casting stage without the UI
  /// ever having offered one.
  Future<List<Partner>> partnersForStage(LifecycleStage stage) async {
    final kind = switch (stage) {
      LifecycleStage.casting => PartnerKind.casting,
      LifecycleStage.cert => PartnerKind.lab,
      _ => null,
    };
    if (kind == null) return const [];
    return listPartners(kind: kind);
  }

  Future<Partner> getPartner(String partnerId) async {
    final partner = await findPartner(partnerId);
    return partner ??
        (throw RecordNotFound(
          message: 'That partner is not on file, or is not yours to see.',
          detail: 'partners.id=$partnerId',
          code: 'PGRST116',
        ));
  }

  Future<Partner?> findPartner(String partnerId) async {
    final row = await guardOrNull(
      () => _client.from('partners').select().eq('id', partnerId).maybeSingle(),
    );
    return row == null ? null : Partner.fromJson(row);
  }

  /// Add a vendor.
  ///
  /// D-004: an unregistered vendor puts the reverse-charge burden on the org, so the GSTIN is
  /// worth capturing at the point the relationship starts. It is not forced — plenty of small
  /// polishing units are unregistered — but a malformed one is refused.
  Future<Partner> createPartner({
    required PartnerKind kind,
    required String name,
    String? contactName,
    String? email,
    String? phone,
    String? gstin,
    Map<String, dynamic> address = const {},
  }) async {
    final orgId = _identity.requireOrgId();
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw const MissingRequiredField(
        message: 'Enter the partner\'s name.',
        code: 'partner_name_empty',
      );
    }

    final row = await guard(
      () => _client
          .from('partners')
          .insert({
            'org_id': orgId,
            'kind': kind.wire,
            'name': trimmedName,
            'contact_name': _blankToNull(contactName),
            'email': _blankToNull(email)?.toLowerCase(),
            'phone': _blankToNull(phone),
            'gstin': _normaliseGstin(gstin),
            'address': address,
          })
          .select()
          .single(),
    );
    return Partner.fromJson(row);
  }

  Future<Partner> updatePartner(
    String partnerId, {
    Opt<PartnerKind>? kind,
    Opt<String>? name,
    Opt<String>? contactName,
    Opt<String>? email,
    Opt<String>? phone,
    Opt<String>? gstin,
    Opt<Map<String, dynamic>>? address,
  }) async {
    final payload = <String, Object?>{};
    writeOpt(payload, 'kind', kind, (v) => v.wire);
    writeOpt(payload, 'name', name, (v) => v.trim());
    writeOpt(payload, 'contact_name', contactName, (v) => v.trim());
    writeOpt(payload, 'email', email, (v) => v.trim().toLowerCase());
    writeOpt(payload, 'phone', phone, (v) => v.trim());
    writeOpt(payload, 'address', address);
    if (gstin != null) payload['gstin'] = _normaliseGstin(gstin.value);

    if (payload.isEmpty) return getPartner(partnerId);

    final row = await guard(
      () => _client.from('partners').update(payload).eq('id', partnerId).select().single(),
    );
    return Partner.fromJson(row);
  }

  /// Retire a partner, or bring one back.
  ///
  /// This is the supported way to stop using a vendor. Deactivating keeps every completed stage
  /// still pointing at the foundry that did the work, which a delete would not — see
  /// [deletePartner].
  Future<Partner> setPartnerActive(String partnerId, {required bool isActive}) async {
    final row = await guard(
      () => _client
          .from('partners')
          .update({'is_active': isActive})
          .eq('id', partnerId)
          .select()
          .single(),
    );
    return Partner.fromJson(row);
  }

  /// Delete a partner that has never held a stage.
  ///
  /// `job_stages.assigned_partner` is `on delete set null`, so an unguarded delete would succeed
  /// and silently erase which foundry cast a piece or which lab certified it — the one record that
  /// makes a defect traceable a year later. Anything with history is refused and pointed at
  /// [setPartnerActive].
  Future<void> deletePartner(String partnerId) async {
    final stages = await countStagesFor(partnerId);
    if (stages > 0) {
      throw InvalidReference(
        message: 'This partner has worked on $stages stage${stages == 1 ? '' : 's'} and cannot '
            'be deleted — that record belongs to those jobs. Deactivate them instead.',
        detail: 'job_stages.assigned_partner references partners.id with on delete set null',
        code: 'partner_in_use',
      );
    }
    await guard(() => _client.from('partners').delete().eq('id', partnerId));
  }

  Future<int> countStagesFor(String partnerId) async {
    final rows = await guard(
      () => _client.from('job_stages').select('id').eq('assigned_partner', partnerId),
    );
    return rows.length;
  }

  // ================================================================ helpers

  /// Uppercase and whitespace-stripped, or null. Refuses a number that is present but malformed:
  /// GSTINs are read off a letterhead and typed, and a wrong state code silently produces the
  /// wrong tax split on every invoice afterwards.
  static String? _normaliseGstin(String? raw) {
    final value = raw?.replaceAll(RegExp(r'\s'), '').toUpperCase();
    if (value == null || value.isEmpty) return null;
    if (_gstinShape.hasMatch(value)) return value;
    throw MissingRequiredField(
      message: 'That GSTIN does not look right. It is 15 characters, like 27ABCDE1234F1Z5 — '
          'two digits for the state, then the PAN. Leave it blank if they are unregistered.',
      detail: 'got "$value"',
      code: 'gstin_shape',
    );
  }

  static String? _blankToNull(String? raw) {
    final value = raw?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// PostgREST's `or=` grammar is comma and parenthesis delimited, so an unescaped
  /// `Patel & Sons (Surat)` would be a syntax error rather than a miss.
  static String? _searchTerm(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final safe = trimmed.replaceAll(RegExp(r'[^\w\s\-#/]'), ' ').trim();
    return safe.isEmpty ? null : safe;
  }
}

// ================================================================= providers

@Riverpod(keepAlive: true)
CustomerRepository customerRepository(Ref ref) => CustomerRepository(
      ref.watch(supabaseProvider),
      ref.watch(repoIdentityProvider),
    );

/// Every retailer, for a picker. Kept alive because the intake wizard opens it on step one and a
/// list of retailers does not change while a job is being written.
@Riverpod(keepAlive: true)
Future<List<Customer>> customerDirectory(Ref ref) =>
    ref.watch(customerRepositoryProvider).listCustomers();

/// Search results for the retailer picker. Auto-disposes: a search is per keystroke, not per app.
@riverpod
Future<List<Customer>> customerSearch(Ref ref, String query) =>
    ref.watch(customerRepositoryProvider).listCustomers(search: query);

@riverpod
Future<Customer?> customer(Ref ref, String customerId) =>
    ref.watch(customerRepositoryProvider).findCustomer(customerId);

/// Active partners of one kind, or all kinds when [kind] is null.
@riverpod
Future<List<Partner>> partnerDirectory(Ref ref, PartnerKind? kind) =>
    ref.watch(customerRepositoryProvider).listPartners(kind: kind);

/// The partners an assignment picker may offer for a stage. Empty for the twelve in-house stages.
@riverpod
Future<List<Partner>> partnersForStage(Ref ref, LifecycleStage stage) =>
    ref.watch(customerRepositoryProvider).partnersForStage(stage);

@riverpod
Future<Partner?> partner(Ref ref, String partnerId) =>
    ref.watch(customerRepositoryProvider).findPartner(partnerId);
