/// The platform console: every workspace (tenant), its figures, and the few acts a super admin
/// performs on one — create it with its first admin, suspend or reactivate it, add an admin,
/// reset a locked-out member's password. Everything below that is read-only here (0014).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/admin/admin_repository.dart';
import 'package:dhanaos/admin/admin_router.dart';
import 'package:dhanaos/admin/widgets/admin_widgets.dart';
import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/shared/widgets/data_pair.dart';
import 'package:dhanaos/shared/widgets/dh_card.dart';
import 'package:dhanaos/shared/widgets/segmented.dart';
import 'package:dhanaos/shared/widgets/status_chip.dart';

final _day = DateFormat('d MMM yyyy');

Widget _tenantStatus(TenantSummary t) => t.isActive
    ? const StatusChip(label: 'Active', tone: ChipTone.success, dense: true, dot: true)
    : const StatusChip(label: 'Suspended', tone: ChipTone.danger, dense: true, dot: true);

Widget _mono(BuildContext context, String text) =>
    Text(text, style: AppTheme.mono(size: 13, color: context.scheme.onSurface));

// ================================================================= list

final class TenantsPage extends ConsumerWidget {
  const TenantsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tenantsProvider);
    return AdminPage(
      title: 'Workspaces',
      subtitle:
          'Every jewellery workshop on DhanaOS. Each is a separate tenant — its data is '
          'visible to no other workspace.',
      actions: [
        FilledButton.icon(
          onPressed: () => context.go(AdminPaths.newTenant),
          icon: const Icon(Icons.add_rounded),
          label: const Text('New workspace'),
        ),
      ],
      children: [
        AsyncBody<List<TenantSummary>>(
          value: async,
          what: 'The workspace list',
          onRetry: () => ref.invalidate(tenantsProvider),
          builder: (tenants) {
            final active = tenants.where((t) => t.isActive).length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StatRow(
                  children: [
                    StatTile(label: 'Workspaces', value: '${tenants.length}'),
                    StatTile(
                      label: 'Suspended',
                      value: '${tenants.length - active}',
                      tone: tenants.length == active ? null : context.scheme.error,
                    ),
                    StatTile(
                      label: 'Active members',
                      value: '${tenants.fold<int>(0, (s, t) => s + t.activeMembers)}',
                    ),
                    StatTile(
                      label: 'Open jobs',
                      value: '${tenants.fold<int>(0, (s, t) => s + t.openJobs)}',
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.md),
                AdminTable<TenantSummary>(
                  rows: tenants,
                  onTap: (t) => context.go(AdminPaths.tenant(t.id)),
                  emptyTitle: 'No workspaces yet',
                  emptyMessage: 'Create the first one — a workshop and its administrator.',
                  columns: [
                    AdminColumn('Workspace', (c, t) => TwoLine(t.name, t.legalName), flex: 4),
                    AdminColumn('Status', (c, t) => _tenantStatus(t), flex: 2),
                    AdminColumn('GSTIN', (c, t) => _mono(c, t.gstin ?? '—'), flex: 3),
                    AdminColumn(
                      'Members',
                      (c, t) => _mono(c, '${t.activeMembers}'),
                      flex: 1,
                      alignEnd: true,
                    ),
                    AdminColumn(
                      'Open jobs',
                      (c, t) => _mono(c, '${t.openJobs}'),
                      flex: 1,
                      alignEnd: true,
                    ),
                    AdminColumn(
                      'Last activity',
                      (c, t) => _mono(
                        c,
                        t.lastActivity == null ? '—' : _day.format(t.lastActivity!.toLocal()),
                      ),
                      flex: 2,
                      alignEnd: true,
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ================================================================= create

final class NewTenantPage extends ConsumerStatefulWidget {
  const NewTenantPage({super.key});

  @override
  ConsumerState<NewTenantPage> createState() => _NewTenantPageState();
}

class _NewTenantPageState extends ConsumerState<NewTenantPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _legal = TextEditingController();
  final _gstin = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _adminName = TextEditingController();
  final _adminEmail = TextEditingController();
  final _password = TextEditingController(text: generateTempPassword());
  String _currency = 'INR';
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _legal, _gstin, _city, _state, _adminName, _adminEmail, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      final orgId = await ref
          .read(adminRepositoryProvider)
          .createTenant(
            name: _name.text,
            legalName: _legal.text,
            gstin: _gstin.text,
            baseCurrency: _currency,
            address: {
              if (_city.text.trim().isNotEmpty) 'city': _city.text.trim(),
              if (_state.text.trim().isNotEmpty) 'state': _state.text.trim(),
              'country': 'IN',
            },
            adminName: _adminName.text,
            adminEmail: _adminEmail.text,
            adminPassword: _password.text,
          );
      ref.invalidate(tenantsProvider);
      if (!mounted) return;
      await showCredentialsDialog(
        context,
        title: '${_name.text.trim()} is ready',
        email: _adminEmail.text.trim().toLowerCase(),
        password: _password.text,
      );
      if (mounted) context.go(AdminPaths.tenant(orgId));
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: AdminPage(
        title: 'New workspace',
        subtitle: 'A workshop and its first administrator. The administrator adds everyone else.',
        maxWidth: 760,
        leading: BackLink(label: 'Workspaces', onTap: () => context.go(AdminPaths.platform)),
        children: [
          DhSectionCard(
            title: 'Workshop',
            child: Column(
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Shree Ganesh Jewellers',
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Enter the workshop name.' : null,
                ),
                const SizedBox(height: Spacing.md),
                TextFormField(
                  controller: _legal,
                  decoration: const InputDecoration(labelText: 'Legal name (for invoices)'),
                ),
                const SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _gstin,
                        textCapitalization: TextCapitalization.characters,
                        style: AppTheme.mono(size: 14, color: context.scheme.onSurface),
                        decoration: const InputDecoration(labelText: 'GSTIN'),
                        validator: (v) {
                          final t = (v ?? '').trim();
                          return t.isEmpty || t.length == 15 ? null : 'A GSTIN has 15 characters.';
                        },
                      ),
                    ),
                    const SizedBox(width: Spacing.md),
                    SizedBox(
                      width: 200,
                      child: DhSegmented<String>(
                        label: 'Currency',
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
                const SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _city,
                        decoration: const InputDecoration(labelText: 'City'),
                      ),
                    ),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: TextFormField(
                        controller: _state,
                        decoration: const InputDecoration(labelText: 'State'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          DhSectionCard(
            title: 'First administrator',
            subtitle: 'Signs in with the temporary password and is asked to choose their own.',
            child: Column(
              children: [
                TextFormField(
                  controller: _adminName,
                  decoration: const InputDecoration(labelText: 'Full name'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Enter their name.' : null,
                ),
                const SizedBox(height: Spacing.md),
                TextFormField(
                  controller: _adminEmail,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                  validator: (v) =>
                      (v ?? '').trim().contains('@') ? null : 'Enter their email address.',
                ),
                const SizedBox(height: Spacing.md),
                TempPasswordField(controller: _password),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.check_rounded),
              label: Text(_busy ? 'Creating…' : 'Create workspace'),
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================= detail

enum _TenantTab { members, customers, partners, jobs, profile }

final class TenantPage extends ConsumerStatefulWidget {
  const TenantPage({super.key, required this.orgId});

  final String orgId;

  @override
  ConsumerState<TenantPage> createState() => _TenantPageState();
}

class _TenantPageState extends ConsumerState<TenantPage> {
  _TenantTab _tab = _TenantTab.members;

  void _refresh() {
    ref
      ..invalidate(tenantProvider(widget.orgId))
      ..invalidate(tenantMembersProvider(widget.orgId))
      ..invalidate(tenantsProvider);
  }

  Future<void> _setActive(TenantSummary t) async {
    final repo = ref.read(adminRepositoryProvider);
    try {
      if (t.isActive) {
        final reason = await reasonDialog(
          context,
          title: 'Suspend ${t.name}?',
          message:
              'Everyone in the workspace is locked out at once — the app and this panel '
              'show them the reason. Their data is kept, and reactivating restores access.',
          confirmLabel: 'Suspend',
        );
        if (reason == null) return;
        await repo.setTenantActive(t.id, active: false, reason: reason);
      } else {
        final ok = await confirmDialog(
          context,
          title: 'Reactivate ${t.name}?',
          message: 'Its members can sign in and work again straight away.',
          confirmLabel: 'Reactivate',
        );
        if (!ok) return;
        await repo.setTenantActive(t.id, active: true);
      }
      _refresh();
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    }
  }

  Future<void> _addAdmin(TenantSummary t) async {
    final result = await showDialog<(String, String, String)>(
      context: context,
      builder: (context) => _AddAdminDialog(workspace: t.name),
    );
    if (result == null) return;
    final (name, email, password) = result;
    try {
      await ref
          .read(adminRepositoryProvider)
          .createMember(
            email: email,
            fullName: name,
            tempPassword: password,
            roles: const {UserRole.admin},
            title: 'Administrator',
            orgId: t.id,
          );
      _refresh();
      if (mounted) {
        await showCredentialsDialog(
          context,
          title: '$name is an admin of ${t.name}',
          email: email.toLowerCase(),
          password: password,
        );
      }
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    }
  }

  Future<void> _resetPassword(AppUser user) async {
    final ok = await confirmDialog(
      context,
      title: 'Reset ${user.fullName}\'s password?',
      message:
          'Their current password stops working. You will see a temporary one to give '
          'them; they choose their own at next sign-in.',
      confirmLabel: 'Reset password',
    );
    if (!ok) return;
    final password = generateTempPassword();
    try {
      await ref.read(adminRepositoryProvider).resetPassword(user.id, password);
      if (mounted) {
        await showCredentialsDialog(
          context,
          title: 'New temporary password',
          email: user.email ?? '',
          password: password,
        );
      }
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(tenantProvider(widget.orgId));
    return AsyncBody<TenantSummary>(
      value: async,
      what: 'This workspace',
      onRetry: _refresh,
      builder: (t) => AdminPage(
        title: t.name,
        subtitle: [
          if (t.legalName != null) t.legalName!,
          'Created ${_day.format(t.createdAt.toLocal())}',
          if (!t.isActive && t.suspendedReason != null) 'Suspended: ${t.suspendedReason}',
        ].join(' · '),
        leading: BackLink(label: 'Workspaces', onTap: () => context.go(AdminPaths.platform)),
        actions: [
          _tenantStatus(t),
          OutlinedButton.icon(
            onPressed: () => _addAdmin(t),
            icon: const Icon(Icons.person_add_alt_rounded),
            label: const Text('Add admin'),
          ),
          if (t.isActive)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: context.scheme.error),
              onPressed: () => _setActive(t),
              icon: const Icon(Icons.pause_circle_outline),
              label: const Text('Suspend'),
            )
          else
            FilledButton.icon(
              onPressed: () => _setActive(t),
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Reactivate'),
            ),
        ],
        children: [
          StatRow(
            children: [
              StatTile(
                label: 'Active members',
                value: '${t.activeMembers}',
                hint: '${t.admins} admin(s)',
              ),
              StatTile(label: 'Customers', value: '${t.customers}'),
              StatTile(label: 'Partners', value: '${t.partners}'),
              StatTile(
                label: 'Open jobs',
                value: '${t.openJobs}',
                hint: '${t.totalJobs} committed in all',
              ),
            ],
          ),
          DhSegmented<_TenantTab>(
            value: _tab,
            segments: const [
              DhSegment(value: _TenantTab.members, label: 'Members'),
              DhSegment(value: _TenantTab.customers, label: 'Customers'),
              DhSegment(value: _TenantTab.partners, label: 'Partners'),
              DhSegment(value: _TenantTab.jobs, label: 'Jobs'),
              DhSegment(value: _TenantTab.profile, label: 'Profile'),
            ],
            onChanged: (v) => setState(() => _tab = v),
          ),
          switch (_tab) {
            _TenantTab.members => _Members(orgId: t.id, onReset: _resetPassword),
            _TenantTab.customers => _Customers(orgId: t.id),
            _TenantTab.partners => _Partners(orgId: t.id),
            _TenantTab.jobs => _Jobs(orgId: t.id, currency: t.baseCurrency),
            _TenantTab.profile => _Profile(tenant: t),
          },
        ],
      ),
    );
  }
}

Widget memberStatus(AppUser u) {
  if (!u.isActive) {
    return const StatusChip(label: 'Deactivated', tone: ChipTone.neutral, dense: true);
  }
  if (u.mustChangePassword) {
    return const StatusChip(label: 'Temporary password', tone: ChipTone.warning, dense: true);
  }
  return const StatusChip(label: 'Active', tone: ChipTone.success, dense: true, dot: true);
}

Widget memberRoles(AppUser u) {
  final roles = u.roles.toList()..sort((a, b) => a.index.compareTo(b.index));
  return Wrap(
    spacing: Spacing.xs,
    runSpacing: Spacing.xs,
    children: [
      for (final r in roles)
        StatusChip(
          label: r.label,
          tone: r == UserRole.admin ? ChipTone.strong : ChipTone.neutral,
          dense: true,
        ),
    ],
  );
}

final class _Members extends ConsumerWidget {
  const _Members({required this.orgId, required this.onReset});

  final String orgId;
  final void Function(AppUser) onReset;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncBody<List<AppUser>>(
    value: ref.watch(tenantMembersProvider(orgId)),
    what: 'The member list',
    onRetry: () => ref.invalidate(tenantMembersProvider(orgId)),
    builder: (members) => AdminTable<AppUser>(
      rows: members,
      emptyTitle: 'No members',
      columns: [
        AdminColumn('Name', (c, u) => TwoLine(u.fullName, u.email, monoSecondary: true), flex: 4),
        AdminColumn('Roles', (c, u) => memberRoles(u), flex: 4),
        AdminColumn('Status', (c, u) => memberStatus(u), flex: 2),
        AdminColumn(
          '',
          (c, u) => TextButton(onPressed: () => onReset(u), child: const Text('Reset password')),
          flex: 2,
          alignEnd: true,
        ),
      ],
    ),
  );
}

final class _Customers extends ConsumerWidget {
  const _Customers({required this.orgId});

  final String orgId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncBody<List<Customer>>(
    value: ref.watch(tenantCustomersProvider(orgId)),
    what: 'The customer list',
    onRetry: () => ref.invalidate(tenantCustomersProvider(orgId)),
    builder: (rows) => AdminTable<Customer>(
      rows: rows,
      emptyTitle: 'No customers',
      columns: [
        AdminColumn('Customer', (c, x) => TwoLine(x.name, x.code, monoSecondary: true), flex: 4),
        AdminColumn('Contact', (c, x) => TwoLine(x.contactName ?? '—', x.email), flex: 4),
        AdminColumn('GSTIN', (c, x) => _mono(c, x.gstin ?? '—'), flex: 3),
        AdminColumn('Currency', (c, x) => _mono(c, x.currency), flex: 1, alignEnd: true),
      ],
    ),
  );
}

final class _Partners extends ConsumerWidget {
  const _Partners({required this.orgId});

  final String orgId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncBody<List<Partner>>(
    value: ref.watch(tenantPartnersProvider(orgId)),
    what: 'The partner list',
    onRetry: () => ref.invalidate(tenantPartnersProvider(orgId)),
    builder: (rows) => AdminTable<Partner>(
      rows: rows,
      emptyTitle: 'No partners',
      columns: [
        AdminColumn('Partner', (c, x) => TwoLine(x.name, x.contactName), flex: 4),
        AdminColumn('Kind', (c, x) => StatusChip(label: x.kind.label, dense: true), flex: 2),
        AdminColumn('GSTIN', (c, x) => _mono(c, x.gstin ?? '—'), flex: 3),
        AdminColumn(
          'Status',
          (c, x) => x.isActive
              ? const StatusChip(label: 'Active', tone: ChipTone.success, dense: true)
              : const StatusChip(label: 'Inactive', dense: true),
          flex: 2,
          alignEnd: true,
        ),
      ],
    ),
  );
}

final class _Jobs extends ConsumerWidget {
  const _Jobs({required this.orgId, required this.currency});

  final String orgId;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncBody<List<Map<String, dynamic>>>(
    value: ref.watch(tenantJobsProvider(orgId)),
    what: 'The job list',
    onRetry: () => ref.invalidate(tenantJobsProvider(orgId)),
    builder: (rows) => AdminTable<Map<String, dynamic>>(
      rows: rows,
      emptyTitle: 'No jobs yet',
      emptyMessage: 'Read-only: jobs are created in the DhanaOS app.',
      columns: [
        AdminColumn(
          'Job',
          (c, j) => TwoLine(
            j['title'] as String? ?? 'Untitled',
            j['display_code'] as String?,
            monoSecondary: true,
          ),
          flex: 4,
        ),
        AdminColumn('Customer', (c, j) => Text(j['customer_name'] as String? ?? '—'), flex: 3),
        AdminColumn(
          'Stage',
          (c, j) => StatusChip(
            label: LifecycleStage.parse(j['current_stage'] as String?)?.label ?? 'Draft',
            dense: true,
          ),
          flex: 2,
        ),
        AdminColumn(
          'Status',
          (c, j) => StatusChip(
            label: JobStatus.parse(j['status'] as String?)?.label ?? '—',
            tone: ChipTone.accent,
            dense: true,
          ),
          flex: 2,
        ),
        AdminColumn(
          'Value',
          (c, j) {
            final total = j['quote_total'] as int?;
            return _mono(
              c,
              total == null
                  ? '—'
                  : Money(total, (j['currency'] as String?)?.trim() ?? currency).format(),
            );
          },
          flex: 2,
          alignEnd: true,
        ),
      ],
    ),
  );
}

final class _Profile extends StatelessWidget {
  const _Profile({required this.tenant});

  final TenantSummary tenant;

  @override
  Widget build(BuildContext context) => DhCard(
    child: DataPairGrid(
      columns: 3,
      children: [
        DataPair(label: 'Name', value: tenant.name),
        DataPair(label: 'Legal name', value: tenant.legalName ?? DataPair.placeholder),
        DataPair.mono(label: 'GSTIN', value: tenant.gstin ?? DataPair.placeholder),
        DataPair.mono(label: 'Base currency', value: tenant.baseCurrency),
        DataPair.timestamp(label: 'Created', utc: tenant.createdAt),
        DataPair.mono(label: 'Workspace id', value: tenant.id),
      ],
    ),
  );
}

final class _AddAdminDialog extends StatefulWidget {
  const _AddAdminDialog({required this.workspace});

  final String workspace;

  @override
  State<_AddAdminDialog> createState() => _AddAdminDialogState();
}

class _AddAdminDialogState extends State<_AddAdminDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController(text: generateTempPassword());

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Add an admin to ${widget.workspace}'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Full name'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Enter their name.' : null,
            ),
            const SizedBox(height: Spacing.md),
            TextFormField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'Email'),
              validator: (v) => (v ?? '').contains('@') ? null : 'Enter their email address.',
            ),
            const SizedBox(height: Spacing.md),
            TempPasswordField(controller: _password),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(
        onPressed: () {
          if (!(_form.currentState?.validate() ?? false)) return;
          Navigator.of(context).pop((_name.text.trim(), _email.text.trim(), _password.text));
        },
        child: const Text('Add admin'),
      ),
    ],
  );
}
