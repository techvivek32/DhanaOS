/// People: the workshop's staff, and the portal logins of its customers and partners.
///
/// Every write is an RPC (0014) — the database refuses the unsafe ones (the last admin, your own
/// admin role, deactivating yourself) with a sentence this page shows as-is.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:dhanaos/admin/admin_repository.dart';
import 'package:dhanaos/admin/admin_router.dart';
import 'package:dhanaos/admin/pages/platform_pages.dart' show memberRoles, memberStatus;
import 'package:dhanaos/admin/widgets/admin_widgets.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/shared/widgets/dh_card.dart';
import 'package:dhanaos/shared/widgets/segmented.dart';
import 'package:dhanaos/shared/widgets/status_chip.dart';

enum _Who { staff, partners, customers, deactivated }

// ================================================================= list

final class TeamPage extends ConsumerStatefulWidget {
  const TeamPage({super.key});

  @override
  ConsumerState<TeamPage> createState() => _TeamPageState();
}

class _TeamPageState extends ConsumerState<TeamPage> {
  _Who _who = _Who.staff;

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(workspaceMembersProvider);
    final customers = ref.watch(workspaceCustomersProvider).value ?? const <Customer>[];
    final partners = ref.watch(workspacePartnersProvider).value ?? const <Partner>[];
    final customerNames = {for (final c in customers) c.id: c.name};
    final partnerNames = {for (final p in partners) p.id: p.name};

    return AdminPage(
      title: 'Team',
      subtitle:
          'Everyone who can sign in to this workspace — staff, and the logins your '
          'customers and partners use.',
      actions: [
        FilledButton.icon(
          onPressed: () => context.go(AdminPaths.newMember),
          icon: const Icon(Icons.person_add_alt_rounded),
          label: const Text('Add member'),
        ),
      ],
      children: [
        AsyncBody<List<AppUser>>(
          value: members,
          what: 'The team',
          onRetry: () => ref.invalidate(workspaceMembersProvider),
          builder: (all) {
            bool matches(AppUser u, _Who who) => switch (who) {
              _Who.deactivated => !u.isActive,
              _Who.staff => u.isActive && u.isInternal,
              _Who.partners => u.isActive && u.isPartner,
              _Who.customers => u.isActive && u.isCustomer,
            };
            int count(_Who w) => all.where((u) => matches(u, w)).length;
            final rows = all.where((u) => matches(u, _who)).toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 640,
                  child: DhSegmented<_Who>(
                    value: _who,
                    segments: [
                      DhSegment(value: _Who.staff, label: 'Staff · ${count(_Who.staff)}'),
                      DhSegment(value: _Who.partners, label: 'Partners · ${count(_Who.partners)}'),
                      DhSegment(
                        value: _Who.customers,
                        label: 'Customers · ${count(_Who.customers)}',
                      ),
                      DhSegment(value: _Who.deactivated, label: 'Off · ${count(_Who.deactivated)}'),
                    ],
                    onChanged: (v) => setState(() => _who = v),
                  ),
                ),
                const SizedBox(height: Spacing.md),
                AdminTable<AppUser>(
                  rows: rows,
                  onTap: (u) => context.go(AdminPaths.member(u.id)),
                  emptyTitle: switch (_who) {
                    _Who.staff => 'No staff yet',
                    _Who.partners => 'No partner logins',
                    _Who.customers => 'No customer logins',
                    _Who.deactivated => 'Nobody is deactivated',
                  },
                  emptyMessage: switch (_who) {
                    _Who.partners =>
                      'Add one from a partner\'s page, so it is tied to that vendor.',
                    _Who.customers =>
                      'Add one from a customer\'s page, so it sees only their orders.',
                    _ => '',
                  },
                  columns: [
                    AdminColumn(
                      'Name',
                      (c, u) => TwoLine(u.fullName, u.email, monoSecondary: true),
                      flex: 4,
                    ),
                    if (_who == _Who.partners || _who == _Who.customers)
                      AdminColumn(
                        _who == _Who.partners ? 'Partner' : 'Customer',
                        (c, u) => Text(
                          (u.partnerId == null ? null : partnerNames[u.partnerId]) ??
                              (u.customerId == null ? null : customerNames[u.customerId]) ??
                              '—',
                        ),
                        flex: 3,
                      )
                    else
                      AdminColumn('Roles', (c, u) => memberRoles(u), flex: 4),
                    AdminColumn('Title', (c, u) => Text(u.title ?? '—'), flex: 2),
                    AdminColumn('Status', (c, u) => memberStatus(u), flex: 2, alignEnd: true),
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

// ================================================================= add / edit

/// Add a member (no [userId]) or edit one. A new partner or customer login arrives with its
/// [partnerId] / [customerId] already chosen, from that record's page.
final class MemberPage extends ConsumerStatefulWidget {
  const MemberPage({super.key, this.userId, this.customerId, this.partnerId});

  final String? userId;
  final String? customerId;
  final String? partnerId;

  @override
  ConsumerState<MemberPage> createState() => _MemberPageState();
}

class _MemberPageState extends ConsumerState<MemberPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _title = TextEditingController();
  final _password = TextEditingController(text: generateTempPassword());

  late PrincipalClass _principal = widget.partnerId != null
      ? PrincipalClass.partner
      : widget.customerId != null
      ? PrincipalClass.customer
      : PrincipalClass.internal;
  late String? _customerId = widget.customerId;
  late String? _partnerId = widget.partnerId;
  Set<UserRole> _roles = {};
  bool _loaded = false;
  bool _busy = false;

  bool get _isNew => widget.userId == null;

  @override
  void dispose() {
    for (final c in [_name, _email, _phone, _title, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(AppUser u) {
    if (_loaded) return;
    _loaded = true;
    _name.text = u.fullName;
    _email.text = u.email ?? '';
    _phone.text = u.phone ?? '';
    _title.text = u.title ?? '';
    _principal = u.principal;
    _roles = u.roles.where(workspaceRoles.contains).toSet();
  }

  void _refresh() {
    ref.invalidate(workspaceMembersProvider);
    if (widget.userId != null) ref.invalidate(workspaceMemberProvider(widget.userId!));
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (_principal == PrincipalClass.internal && _roles.isEmpty) {
      showAdminError(context, 'Give the member at least one role.');
      return;
    }
    setState(() => _busy = true);
    final repo = ref.read(adminRepositoryProvider);
    try {
      if (_isNew) {
        await repo.createMember(
          email: _email.text,
          fullName: _name.text,
          tempPassword: _password.text,
          principal: _principal,
          roles: _roles,
          title: _title.text,
          phone: _phone.text,
          customerId: _principal == PrincipalClass.customer ? _customerId : null,
          partnerId: _principal == PrincipalClass.partner ? _partnerId : null,
        );
        _refresh();
        if (!mounted) return;
        await showCredentialsDialog(
          context,
          title: '${_name.text.trim()} can sign in',
          email: _email.text.trim().toLowerCase(),
          password: _password.text,
        );
        if (mounted) context.go(AdminPaths.team);
      } else {
        await repo.updateMember(
          widget.userId!,
          fullName: _name.text,
          title: _title.text,
          phone: _phone.text,
          roles: _principal == PrincipalClass.internal ? _roles : null,
        );
        _refresh();
        if (mounted) showAdminNotice(context, 'Saved.');
      }
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetPassword(AppUser u) async {
    final ok = await confirmDialog(
      context,
      title: 'Reset ${u.fullName}\'s password?',
      message:
          'Their current password stops working. You will see a temporary one to give '
          'them; they choose their own at next sign-in.',
      confirmLabel: 'Reset password',
    );
    if (!ok) return;
    final password = generateTempPassword();
    try {
      await ref.read(adminRepositoryProvider).resetPassword(u.id, password);
      _refresh();
      if (mounted) {
        await showCredentialsDialog(
          context,
          title: 'New temporary password',
          email: u.email ?? '',
          password: password,
        );
      }
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    }
  }

  Future<void> _setActive(AppUser u) async {
    final turningOff = u.isActive;
    final ok = await confirmDialog(
      context,
      title: turningOff ? 'Deactivate ${u.fullName}?' : 'Reactivate ${u.fullName}?',
      message: turningOff
          ? 'They are signed out everywhere and cannot sign in again. Everything they recorded '
                'stays on the jobs. You can reactivate them later.'
          : 'They can sign in again with their existing password.',
      confirmLabel: turningOff ? 'Deactivate' : 'Reactivate',
      destructive: turningOff,
    );
    if (!ok) return;
    try {
      await ref.read(adminRepositoryProvider).setMemberActive(u.id, active: !turningOff);
      _refresh();
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isNew) return _page(context, null);
    return AsyncBody<AppUser>(
      value: ref.watch(workspaceMemberProvider(widget.userId!)),
      what: 'This member',
      onRetry: _refresh,
      builder: (u) {
        _fill(u);
        return _page(context, u);
      },
    );
  }

  Widget _page(BuildContext context, AppUser? existing) {
    final me = ref.watch(currentUserProvider).value;
    final isMe = existing != null && existing.id == me?.id;
    final customers = ref.watch(workspaceCustomersProvider).value ?? const <Customer>[];
    final partners = ref.watch(workspacePartnersProvider).value ?? const <Partner>[];
    final scheme = context.scheme;

    return Form(
      key: _form,
      child: AdminPage(
        title: existing?.fullName ?? 'Add member',
        subtitle: existing == null
            ? 'They get a temporary password from you and choose their own at first sign-in.'
            : existing.email,
        maxWidth: 820,
        leading: BackLink(label: 'Team', onTap: () => context.go(AdminPaths.team)),
        actions: [
          if (existing != null) ...[
            memberStatus(existing),
            if (!isMe)
              OutlinedButton.icon(
                onPressed: () => _resetPassword(existing),
                icon: const Icon(Icons.lock_reset_rounded),
                label: const Text('Reset password'),
              ),
            if (!isMe)
              OutlinedButton.icon(
                style: existing.isActive
                    ? OutlinedButton.styleFrom(foregroundColor: scheme.error)
                    : null,
                onPressed: () => _setActive(existing),
                icon: Icon(
                  existing.isActive ? Icons.person_off_outlined : Icons.person_outline_rounded,
                ),
                label: Text(existing.isActive ? 'Deactivate' : 'Reactivate'),
              ),
          ],
        ],
        children: [
          if (existing == null)
            DhSectionCard(
              title: 'Kind of login',
              child: DhSegmented<PrincipalClass>(
                value: _principal,
                segments: const [
                  DhSegment(
                    value: PrincipalClass.internal,
                    label: 'Staff',
                    icon: Icons.badge_outlined,
                  ),
                  DhSegment(
                    value: PrincipalClass.partner,
                    label: 'Partner',
                    icon: Icons.handshake_outlined,
                  ),
                  DhSegment(
                    value: PrincipalClass.customer,
                    label: 'Customer',
                    icon: Icons.storefront_outlined,
                  ),
                ],
                onChanged: (v) => setState(() => _principal = v),
              ),
            ),
          DhSectionCard(
            title: 'Details',
            child: Column(
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Full name'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Enter their name.' : null,
                ),
                const SizedBox(height: Spacing.md),
                TextFormField(
                  controller: _email,
                  enabled: existing == null,
                  keyboardType: TextInputType.emailAddress,
                  style: AppTheme.mono(size: 14, color: scheme.onSurface),
                  decoration: InputDecoration(
                    labelText: 'Email (their sign-in)',
                    helperText: existing == null ? null : 'The sign-in email cannot be changed.',
                  ),
                  validator: (v) =>
                      (v ?? '').trim().contains('@') ? null : 'Enter their email address.',
                ),
                const SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _title,
                        decoration: const InputDecoration(
                          labelText: 'Title',
                          hintText: 'Senior Setter',
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: TextFormField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        style: AppTheme.mono(size: 14, color: scheme.onSurface),
                        decoration: const InputDecoration(labelText: 'Phone'),
                      ),
                    ),
                  ],
                ),
                if (existing == null && _principal == PrincipalClass.partner) ...[
                  const SizedBox(height: Spacing.md),
                  DropdownButtonFormField<String>(
                    initialValue: _partnerId,
                    decoration: const InputDecoration(labelText: 'Partner (vendor)'),
                    items: [
                      for (final p in partners.where((p) => p.isActive))
                        DropdownMenuItem(value: p.id, child: Text('${p.name} · ${p.kind.label}')),
                    ],
                    onChanged: (v) => setState(() => _partnerId = v),
                    validator: (v) => v == null ? 'Choose the partner this login is for.' : null,
                  ),
                ],
                if (existing == null && _principal == PrincipalClass.customer) ...[
                  const SizedBox(height: Spacing.md),
                  DropdownButtonFormField<String>(
                    initialValue: _customerId,
                    decoration: const InputDecoration(labelText: 'Customer'),
                    items: [
                      for (final c in customers) DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) => setState(() => _customerId = v),
                    validator: (v) => v == null ? 'Choose the customer this login is for.' : null,
                  ),
                ],
              ],
            ),
          ),
          if (_principal == PrincipalClass.internal)
            DhSectionCard(
              title: 'Roles',
              subtitle: isMe
                  ? 'You cannot remove your own admin role — another admin has to.'
                  : 'Tick every hat they wear. What each unlocks is enforced by the database.',
              child: RoleChecklist(
                selected: _roles,
                onChanged: (next) => setState(() => _roles = next),
              ),
            )
          else
            DhCard(
              child: Row(
                children: [
                  StatusChip(
                    label: _principal == PrincipalClass.partner
                        ? 'Partner login'
                        : 'Customer login',
                    tone: ChipTone.accent,
                    dense: true,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      roleDescription(
                        _principal == PrincipalClass.partner ? UserRole.partner : UserRole.customer,
                      ),
                      style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          if (existing == null)
            DhSectionCard(
              title: 'Sign-in',
              child: TempPasswordField(controller: _password),
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
                    ? 'Create login'
                    : 'Save changes',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
