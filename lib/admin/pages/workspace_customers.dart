/// Customers (retailers) and partners (vendors, labs, couriers) — the records jobs refer to —
/// and the portal logins that belong to each.
///
/// Writes go through the app's own [CustomerRepository], the same code the intake wizard uses to
/// add a retailer, so a record looks the same whichever side created it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:dhanaos/admin/admin_repository.dart';
import 'package:dhanaos/admin/admin_router.dart';
import 'package:dhanaos/admin/pages/platform_pages.dart' show memberStatus;
import 'package:dhanaos/admin/widgets/admin_widgets.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/customer_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart' show Opt;
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/shared/widgets/dh_card.dart';
import 'package:dhanaos/shared/widgets/segmented.dart';
import 'package:dhanaos/shared/widgets/status_chip.dart';

Widget _mono(BuildContext context, String text) =>
    Text(text, style: AppTheme.mono(size: 13, color: context.scheme.onSurface));

Opt<String> _opt(TextEditingController c) {
  final text = c.text.trim();
  return text.isEmpty ? const Opt.clear() : Opt(text);
}

String? _gstinCheck(String? value) {
  final t = (value ?? '').trim();
  return t.isEmpty || t.length == 15 ? null : 'A GSTIN has 15 characters.';
}

/// The logins tied to one customer or partner, with the way to add another.
final class _Logins extends ConsumerWidget {
  const _Logins({required this.belongs, required this.addPath, required this.noun});

  final bool Function(AppUser) belongs;
  final String addPath;
  final String noun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(workspaceMembersProvider).value ?? const <AppUser>[];
    final logins = members.where(belongs).toList();
    return DhSectionCard(
      title: '$noun logins',
      subtitle: noun == 'Portal'
          ? 'Their buyers sign in to the app and see only this customer\'s orders.'
          : 'Their staff sign in to the app and see only the jobs sent to this partner.',
      action: TextButton.icon(
        onPressed: () => context.go(addPath),
        icon: const Icon(Icons.person_add_alt_rounded, size: 18),
        label: const Text('Add login'),
      ),
      child: logins.isEmpty
          ? Text(
              'No logins yet.',
              style: context.text.bodyMedium?.copyWith(color: context.scheme.onSurfaceVariant),
            )
          : Column(
              children: [
                for (final u in logins)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(u.fullName),
                    subtitle: Text(
                      u.email ?? '',
                      style: AppTheme.mono(size: 12, color: context.scheme.onSurfaceVariant),
                    ),
                    trailing: memberStatus(u),
                    onTap: () => context.go(AdminPaths.member(u.id)),
                  ),
              ],
            ),
    );
  }
}

// ================================================================= customers

final class CustomersPage extends ConsumerWidget {
  const CustomersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(workspaceMembersProvider).value ?? const <AppUser>[];
    return AdminPage(
      title: 'Customers',
      subtitle:
          'The retailers you make for. GSTIN and currency decide how their invoices are taxed.',
      actions: [
        FilledButton.icon(
          onPressed: () => context.go(AdminPaths.newCustomer),
          icon: const Icon(Icons.add_business_outlined),
          label: const Text('Add customer'),
        ),
      ],
      children: [
        AsyncBody<List<Customer>>(
          value: ref.watch(workspaceCustomersProvider),
          what: 'The customer list',
          onRetry: () => ref.invalidate(workspaceCustomersProvider),
          builder: (rows) => AdminTable<Customer>(
            rows: rows,
            onTap: (c) => context.go(AdminPaths.customer(c.id)),
            emptyTitle: 'No customers yet',
            emptyMessage: 'Add your first retailer, or let the intake wizard add one with a job.',
            columns: [
              AdminColumn(
                'Customer',
                (c, x) => TwoLine(x.name, x.code, monoSecondary: true),
                flex: 4,
              ),
              AdminColumn('Contact', (c, x) => TwoLine(x.contactName ?? '—', x.email), flex: 4),
              AdminColumn('GSTIN', (c, x) => _mono(c, x.gstin ?? '—'), flex: 3),
              AdminColumn('Terms', (c, x) => Text(x.paymentTerms ?? '—'), flex: 2),
              AdminColumn(
                'Logins',
                (c, x) => _mono(c, '${members.where((u) => u.customerId == x.id).length}'),
                flex: 1,
                alignEnd: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final class CustomerPage extends ConsumerStatefulWidget {
  const CustomerPage({super.key, this.customerId});

  final String? customerId;

  @override
  ConsumerState<CustomerPage> createState() => _CustomerPageState();
}

class _CustomerPageState extends ConsumerState<CustomerPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _contact = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _gstin = TextEditingController();
  final _terms = TextEditingController();
  final _line1 = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _pin = TextEditingController();
  final _notes = TextEditingController();
  String _currency = 'INR';
  bool _loaded = false;
  bool _busy = false;

  List<TextEditingController> get _all => [
    _name,
    _code,
    _contact,
    _email,
    _phone,
    _gstin,
    _terms,
    _line1,
    _city,
    _state,
    _pin,
    _notes,
  ];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(Customer c) {
    if (_loaded) return;
    _loaded = true;
    _name.text = c.name;
    _code.text = c.code ?? '';
    _contact.text = c.contactName ?? '';
    _email.text = c.email ?? '';
    _phone.text = c.phone ?? '';
    _gstin.text = c.gstin ?? '';
    _terms.text = c.paymentTerms ?? '';
    _line1.text = c.address['line1'] as String? ?? '';
    _city.text = c.address['city'] as String? ?? '';
    _state.text = c.address['state'] as String? ?? '';
    _pin.text = c.address['pin'] as String? ?? '';
    _notes.text = c.notes ?? '';
    _currency = c.currency;
  }

  Map<String, dynamic> get _address => {
    for (final (key, c) in [('line1', _line1), ('city', _city), ('state', _state), ('pin', _pin)])
      if (c.text.trim().isNotEmpty) key: c.text.trim(),
  };

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    final repo = ref.read(customerRepositoryProvider);
    try {
      if (widget.customerId == null) {
        final created = await repo.createCustomer(
          name: _name.text,
          code: _code.text,
          contactName: _contact.text,
          email: _email.text,
          phone: _phone.text,
          gstin: _gstin.text,
          address: _address,
          paymentTerms: _terms.text,
          currency: _currency,
          notes: _notes.text,
        );
        ref.invalidate(workspaceCustomersProvider);
        if (mounted) context.go(AdminPaths.customer(created.id));
      } else {
        await repo.updateCustomer(
          widget.customerId!,
          name: Opt(_name.text.trim()),
          code: _opt(_code),
          contactName: _opt(_contact),
          email: _opt(_email),
          phone: _opt(_phone),
          gstin: _opt(_gstin),
          address: Opt(_address),
          paymentTerms: _opt(_terms),
          currency: Opt(_currency),
          notes: _opt(_notes),
        );
        ref
          ..invalidate(workspaceCustomersProvider)
          ..invalidate(customerProvider(widget.customerId!));
        if (mounted) showAdminNotice(context, 'Saved.');
      }
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.customerId;
    if (id == null) return _page(context, null);
    return AsyncBody<Customer?>(
      value: ref.watch(customerProvider(id)),
      what: 'This customer',
      onRetry: () => ref.invalidate(customerProvider(id)),
      builder: (c) {
        if (c == null) return const SizedBox.shrink();
        _fill(c);
        return _page(context, c);
      },
    );
  }

  Widget _page(BuildContext context, Customer? existing) {
    final scheme = context.scheme;
    Widget field(
      TextEditingController c,
      String label, {
      bool mono = false,
      String? Function(String?)? validator,
      int lines = 1,
    }) => TextFormField(
      controller: c,
      maxLines: lines,
      style: mono ? AppTheme.mono(size: 14, color: scheme.onSurface) : null,
      textCapitalization: mono ? TextCapitalization.characters : TextCapitalization.none,
      decoration: InputDecoration(labelText: label),
      validator: validator,
    );
    Widget pair(Widget a, Widget b) => Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: Spacing.md),
        Expanded(child: b),
      ],
    );

    return Form(
      key: _form,
      child: AdminPage(
        title: existing?.name ?? 'Add customer',
        subtitle: existing == null ? 'A retailer you make pieces for.' : existing.code,
        maxWidth: 860,
        leading: BackLink(label: 'Customers', onTap: () => context.go(AdminPaths.customers)),
        children: [
          DhSectionCard(
            title: 'Customer',
            child: Column(
              children: [
                pair(
                  field(
                    _name,
                    'Name',
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Enter the name.' : null,
                  ),
                  field(_code, 'Short code', mono: true),
                ),
                const SizedBox(height: Spacing.md),
                pair(field(_contact, 'Contact person'), field(_email, 'Email')),
                const SizedBox(height: Spacing.md),
                pair(field(_phone, 'Phone', mono: true), field(_terms, 'Payment terms')),
                const SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Expanded(child: field(_gstin, 'GSTIN', mono: true, validator: _gstinCheck)),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: DhSegmented<String>(
                        label: 'Invoice currency',
                        value: _currency,
                        segments: const [
                          DhSegment(value: 'INR', label: 'INR'),
                          DhSegment(value: 'USD', label: 'USD'),
                        ],
                        onChanged: (v) => setState(() => _currency = v),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          DhSectionCard(
            title: 'Address',
            subtitle: 'The state decides CGST + SGST or IGST on their invoices.',
            child: Column(
              children: [
                field(_line1, 'Street'),
                const SizedBox(height: Spacing.md),
                pair(field(_city, 'City'), field(_state, 'State')),
                const SizedBox(height: Spacing.md),
                pair(field(_pin, 'PIN', mono: true), field(_notes, 'Notes')),
              ],
            ),
          ),
          if (existing != null)
            _Logins(
              noun: 'Portal',
              belongs: (u) => u.customerId == existing.id,
              addPath: AdminPaths.newLoginFor(customerId: existing.id),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.check_rounded),
              label: Text(
                _busy
                    ? 'Saving…'
                    : existing == null
                    ? 'Add customer'
                    : 'Save changes',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================= partners

final class PartnersPage extends ConsumerWidget {
  const PartnersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(workspaceMembersProvider).value ?? const <AppUser>[];
    return AdminPage(
      title: 'Partners',
      subtitle:
          'Casting houses, gem labs, stone suppliers and couriers. A partner sees only the '
          'stages you assign to it.',
      actions: [
        FilledButton.icon(
          onPressed: () => context.go(AdminPaths.newPartner),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add partner'),
        ),
      ],
      children: [
        AsyncBody<List<Partner>>(
          value: ref.watch(workspacePartnersProvider),
          what: 'The partner list',
          onRetry: () => ref.invalidate(workspacePartnersProvider),
          builder: (rows) => AdminTable<Partner>(
            rows: rows,
            onTap: (p) => context.go(AdminPaths.partner(p.id)),
            emptyTitle: 'No partners yet',
            columns: [
              AdminColumn('Partner', (c, x) => TwoLine(x.name, x.contactName), flex: 4),
              AdminColumn('Kind', (c, x) => StatusChip(label: x.kind.label, dense: true), flex: 2),
              AdminColumn('GSTIN', (c, x) => _mono(c, x.gstin ?? '—'), flex: 3),
              AdminColumn(
                'Logins',
                (c, x) => _mono(c, '${members.where((u) => u.partnerId == x.id).length}'),
                flex: 1,
                alignEnd: true,
              ),
              AdminColumn(
                'Status',
                (c, x) => x.isActive
                    ? const StatusChip(
                        label: 'Active',
                        tone: ChipTone.success,
                        dense: true,
                        dot: true,
                      )
                    : const StatusChip(label: 'Inactive', dense: true),
                flex: 2,
                alignEnd: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final class PartnerPage extends ConsumerStatefulWidget {
  const PartnerPage({super.key, this.partnerId});

  final String? partnerId;

  @override
  ConsumerState<PartnerPage> createState() => _PartnerPageState();
}

class _PartnerPageState extends ConsumerState<PartnerPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _contact = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _gstin = TextEditingController();
  final _city = TextEditingController();
  PartnerKind _kind = PartnerKind.casting;
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _contact, _email, _phone, _gstin, _city]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(Partner p) {
    if (_loaded) return;
    _loaded = true;
    _name.text = p.name;
    _contact.text = p.contactName ?? '';
    _email.text = p.email ?? '';
    _phone.text = p.phone ?? '';
    _gstin.text = p.gstin ?? '';
    _city.text = p.address['city'] as String? ?? '';
    _kind = p.kind;
  }

  Map<String, dynamic> get _address => {
    if (_city.text.trim().isNotEmpty) 'city': _city.text.trim(),
  };

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    final repo = ref.read(customerRepositoryProvider);
    try {
      if (widget.partnerId == null) {
        final created = await repo.createPartner(
          kind: _kind,
          name: _name.text,
          contactName: _contact.text,
          email: _email.text,
          phone: _phone.text,
          gstin: _gstin.text,
          address: _address,
        );
        ref.invalidate(workspacePartnersProvider);
        if (mounted) context.go(AdminPaths.partner(created.id));
      } else {
        await repo.updatePartner(
          widget.partnerId!,
          kind: Opt(_kind),
          name: Opt(_name.text.trim()),
          contactName: _opt(_contact),
          email: _opt(_email),
          phone: _opt(_phone),
          gstin: _opt(_gstin),
          address: Opt(_address),
        );
        ref
          ..invalidate(workspacePartnersProvider)
          ..invalidate(partnerProvider(widget.partnerId!));
        if (mounted) showAdminNotice(context, 'Saved.');
      }
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleActive(Partner p) async {
    try {
      await ref.read(customerRepositoryProvider).setPartnerActive(p.id, isActive: !p.isActive);
      ref
        ..invalidate(workspacePartnersProvider)
        ..invalidate(partnerProvider(p.id));
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.partnerId;
    if (id == null) return _page(context, null);
    return AsyncBody<Partner?>(
      value: ref.watch(partnerProvider(id)),
      what: 'This partner',
      onRetry: () => ref.invalidate(partnerProvider(id)),
      builder: (p) {
        if (p == null) return const SizedBox.shrink();
        _fill(p);
        return _page(context, p);
      },
    );
  }

  Widget _page(BuildContext context, Partner? existing) {
    final scheme = context.scheme;
    Widget field(
      TextEditingController c,
      String label, {
      bool mono = false,
      String? Function(String?)? validator,
    }) => TextFormField(
      controller: c,
      style: mono ? AppTheme.mono(size: 14, color: scheme.onSurface) : null,
      textCapitalization: mono ? TextCapitalization.characters : TextCapitalization.none,
      decoration: InputDecoration(labelText: label),
      validator: validator,
    );
    Widget pair(Widget a, Widget b) => Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: Spacing.md),
        Expanded(child: b),
      ],
    );

    return Form(
      key: _form,
      child: AdminPage(
        title: existing?.name ?? 'Add partner',
        subtitle: existing?.kind.label ?? 'A vendor, lab or courier you send work to.',
        maxWidth: 860,
        leading: BackLink(label: 'Partners', onTap: () => context.go(AdminPaths.partners)),
        actions: [
          if (existing != null)
            OutlinedButton(
              onPressed: () => _toggleActive(existing),
              child: Text(existing.isActive ? 'Mark inactive' : 'Mark active'),
            ),
        ],
        children: [
          DhSectionCard(
            title: 'Partner',
            child: Column(
              children: [
                DropdownButtonFormField<PartnerKind>(
                  initialValue: _kind,
                  decoration: const InputDecoration(labelText: 'Kind'),
                  items: [
                    for (final k in PartnerKind.values)
                      DropdownMenuItem(value: k, child: Text(k.label)),
                  ],
                  onChanged: (v) => setState(() => _kind = v ?? _kind),
                ),
                const SizedBox(height: Spacing.md),
                pair(
                  field(
                    _name,
                    'Name',
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Enter the name.' : null,
                  ),
                  field(_contact, 'Contact person'),
                ),
                const SizedBox(height: Spacing.md),
                pair(field(_email, 'Email'), field(_phone, 'Phone', mono: true)),
                const SizedBox(height: Spacing.md),
                pair(
                  field(_gstin, 'GSTIN', mono: true, validator: _gstinCheck),
                  field(_city, 'City'),
                ),
              ],
            ),
          ),
          if (existing != null)
            _Logins(
              noun: 'Vendor',
              belongs: (u) => u.partnerId == existing.id,
              addPath: AdminPaths.newLoginFor(partnerId: existing.id),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.check_rounded),
              label: Text(
                _busy
                    ? 'Saving…'
                    : existing == null
                    ? 'Add partner'
                    : 'Save changes',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
