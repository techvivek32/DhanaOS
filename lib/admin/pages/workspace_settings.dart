/// Workspace settings: the invoice profile (D-004), the metal rates quotes lock against, and the
/// benches and machines stage completions are credited to.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/admin/admin_repository.dart';
import 'package:dhanaos/admin/widgets/admin_widgets.dart';
import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/shared/widgets/dh_card.dart';
import 'package:dhanaos/shared/widgets/segmented.dart';
import 'package:dhanaos/shared/widgets/status_chip.dart';

// ================================================================= organisation

final class OrganisationPage extends ConsumerStatefulWidget {
  const OrganisationPage({super.key});

  @override
  ConsumerState<OrganisationPage> createState() => _OrganisationPageState();
}

class _OrganisationPageState extends ConsumerState<OrganisationPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _legal = TextEditingController();
  final _gstin = TextEditingController();
  final _pan = TextEditingController();
  final _line1 = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _pin = TextEditingController();
  String _currency = 'INR';
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _legal, _gstin, _pan, _line1, _city, _state, _pin]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(Org o) {
    if (_loaded) return;
    _loaded = true;
    _name.text = o.name;
    _legal.text = o.legalName ?? '';
    _gstin.text = o.gstin ?? '';
    _pan.text = o.pan ?? '';
    _line1.text = o.address['line1'] as String? ?? '';
    _city.text = o.address['city'] as String? ?? '';
    _state.text = o.address['state'] as String? ?? '';
    _pin.text = o.address['pin'] as String? ?? '';
    _currency = o.baseCurrency;
  }

  Future<void> _save(Org o) async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateOrg(
            o.id,
            name: _name.text,
            legalName: _legal.text,
            gstin: _gstin.text,
            pan: _pan.text,
            baseCurrency: _currency,
            address: {
              ...o.address,
              'line1': _line1.text.trim(),
              'city': _city.text.trim(),
              'state': _state.text.trim(),
              'pin': _pin.text.trim(),
            }..removeWhere((_, v) => v == ''),
          );
      ref
        ..invalidate(workspaceOrgProvider(o.id))
        ..invalidate(currentUserProvider);
      if (mounted) showAdminNotice(context, 'Saved.');
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final orgId = ref.watch(currentOrgIdProvider);
    if (orgId == null) return const SizedBox.shrink();
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

    return AsyncBody<Org>(
      value: ref.watch(workspaceOrgProvider(orgId)),
      what: 'The workspace profile',
      onRetry: () => ref.invalidate(workspaceOrgProvider(orgId)),
      builder: (o) {
        _fill(o);
        return Form(
          key: _form,
          child: AdminPage(
            title: 'Organisation',
            subtitle:
                'What every tax invoice prints. The GSTIN\'s state code also decides '
                'whether a sale is intrastate (CGST + SGST) or interstate (IGST).',
            maxWidth: 860,
            children: [
              DhSectionCard(
                title: 'Identity',
                child: Column(
                  children: [
                    pair(
                      field(
                        _name,
                        'Workspace name',
                        validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name.' : null,
                      ),
                      field(_legal, 'Legal name'),
                    ),
                    const SizedBox(height: Spacing.md),
                    pair(
                      field(
                        _gstin,
                        'GSTIN',
                        mono: true,
                        validator: (v) {
                          final t = (v ?? '').trim();
                          return t.isEmpty || t.length == 15 ? null : 'A GSTIN has 15 characters.';
                        },
                      ),
                      field(
                        _pan,
                        'PAN',
                        mono: true,
                        validator: (v) {
                          final t = (v ?? '').trim();
                          return t.isEmpty || t.length == 10 ? null : 'A PAN has 10 characters.';
                        },
                      ),
                    ),
                    const SizedBox(height: Spacing.md),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 260,
                        child: DhSegmented<String>(
                          label: 'Base currency',
                          value: _currency,
                          segments: const [
                            DhSegment(value: 'INR', label: 'INR'),
                            DhSegment(value: 'USD', label: 'USD'),
                          ],
                          onChanged: (v) => setState(() => _currency = v),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              DhSectionCard(
                title: 'Registered address',
                child: Column(
                  children: [
                    field(_line1, 'Street'),
                    const SizedBox(height: Spacing.md),
                    pair(field(_city, 'City'), field(_state, 'State')),
                    const SizedBox(height: Spacing.md),
                    pair(field(_pin, 'PIN', mono: true), const SizedBox.shrink()),
                  ],
                ),
              ),
              DhCard(
                tone: DhCardTone.inset,
                child: Text(
                  'The job-code counter (${o.jobSeqYear} · next DH-${o.jobSeqYear}-'
                  '${(o.jobSeq + 1).toString().padLeft(5, '0')}) is not editable: job codes are '
                  'minted by the database so two orders can never share one.',
                  style: AppTheme.mono(size: 12, color: scheme.onSurfaceVariant),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _save(o),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(_busy ? 'Saving…' : 'Save changes'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================= metal rates

final _stamp = DateFormat('d MMM yyyy · HH:mm');

final class RatesPage extends ConsumerWidget {
  const RatesPage({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final orgId = ref.read(currentOrgIdProvider);
    if (orgId == null) return;
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _RateDialog(orgId: orgId),
    );
    if (added ?? false) ref.invalidate(workspaceRatesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminPage(
      title: 'Metal rates',
      subtitle:
          'The newest rate for each metal and purity is what a new quote locks against. '
          'Rates are never edited — a new one is added.',
      actions: [
        FilledButton.icon(
          onPressed: () => _add(context, ref),
          icon: const Icon(Icons.add_chart_rounded),
          label: const Text('Add today\'s rate'),
        ),
      ],
      children: [
        AsyncBody<List<MetalRate>>(
          value: ref.watch(workspaceRatesProvider),
          what: 'The rate list',
          onRetry: () => ref.invalidate(workspaceRatesProvider),
          builder: (rates) {
            final seen = <String>{};
            final current = [
              for (final r in rates)
                if (seen.add('${r.baseMetal.wire}/${r.purity?.wire}/${r.currency}')) r,
            ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StatRow(
                  minTileWidth: 180,
                  children: [
                    for (final r in current)
                      StatTile(
                        label: '${r.purity?.label ?? ''} ${r.baseMetal.label}'.trim(),
                        value: r.ratePerG.format(),
                        hint: 'per gram · ${_stamp.format(r.effectiveAt.toLocal())}',
                      ),
                  ],
                ),
                const SizedBox(height: Spacing.md),
                AdminTable<MetalRate>(
                  rows: rates,
                  emptyTitle: 'No rates yet',
                  emptyMessage: 'Add the day\'s rate before the first quote is priced.',
                  columns: [
                    AdminColumn(
                      'Metal',
                      (c, r) => Text('${r.purity?.label ?? ''} ${r.baseMetal.label}'.trim()),
                      flex: 3,
                    ),
                    AdminColumn(
                      'Per gram',
                      (c, r) => Text(
                        r.ratePerG.format(),
                        style: AppTheme.mono(size: 13, color: c.scheme.onSurface),
                      ),
                      flex: 2,
                      alignEnd: true,
                    ),
                    AdminColumn('Source', (c, r) => Text(r.source ?? '—'), flex: 2),
                    AdminColumn(
                      'Effective',
                      (c, r) => Text(
                        _stamp.format(r.effectiveAt.toLocal()),
                        style: AppTheme.mono(size: 12, color: c.scheme.onSurfaceVariant),
                      ),
                      flex: 3,
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

final class _RateDialog extends ConsumerStatefulWidget {
  const _RateDialog({required this.orgId});

  final String orgId;

  @override
  ConsumerState<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends ConsumerState<_RateDialog> {
  final _form = GlobalKey<FormState>();
  final _rate = TextEditingController();
  final _source = TextEditingController(text: 'manual');
  BaseMetal _metal = BaseMetal.gold;
  MetalPurity? _purity = MetalPurity.k22;
  String _currency = 'INR';
  bool _busy = false;

  static const _purities = {
    BaseMetal.gold: [
      MetalPurity.k24,
      MetalPurity.k22,
      MetalPurity.k18,
      MetalPurity.k14,
      MetalPurity.k9,
    ],
    BaseMetal.platinum: [MetalPurity.pt950, MetalPurity.pt900],
    BaseMetal.silver: [MetalPurity.s925],
  };

  @override
  void dispose() {
    _rate.dispose();
    _source.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .addRate(
            orgId: widget.orgId,
            metal: _metal,
            purity: _purity,
            // D-004: money is integer minor units, parsed once at the edge.
            ratePerGMinor: Money.parse(_rate.text, _currency).minor,
            currency: _currency,
            source: _source.text,
          );
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final purities = _purities[_metal] ?? const <MetalPurity>[];
    return AlertDialog(
      title: const Text('Add a rate'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<BaseMetal>(
                initialValue: _metal,
                decoration: const InputDecoration(labelText: 'Metal'),
                items: [
                  for (final m in [
                    BaseMetal.gold,
                    BaseMetal.platinum,
                    BaseMetal.silver,
                    BaseMetal.palladium,
                  ])
                    DropdownMenuItem(value: m, child: Text(m.label)),
                ],
                onChanged: (m) => setState(() {
                  _metal = m ?? _metal;
                  final options = _purities[_metal];
                  _purity = options == null || options.isEmpty ? null : options.first;
                }),
              ),
              if (purities.isNotEmpty) ...[
                const SizedBox(height: Spacing.md),
                DropdownButtonFormField<MetalPurity>(
                  key: ValueKey(_metal),
                  initialValue: _purity,
                  decoration: const InputDecoration(labelText: 'Purity'),
                  items: [
                    for (final p in purities) DropdownMenuItem(value: p, child: Text(p.label)),
                  ],
                  onChanged: (p) => setState(() => _purity = p),
                ),
              ],
              const SizedBox(height: Spacing.md),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _rate,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: AppTheme.mono(size: 15, color: context.scheme.onSurface),
                      decoration: InputDecoration(labelText: 'Rate per gram ($_currency)'),
                      validator: (v) => Money.parse(v ?? '', _currency).minor > 0
                          ? null
                          : 'Enter the rate per gram.',
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  SizedBox(
                    width: 140,
                    child: DhSegmented<String>(
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
              TextFormField(
                controller: _source,
                decoration: const InputDecoration(
                  labelText: 'Source',
                  hintText: 'IBJA, bullion desk…',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Add rate')),
      ],
    );
  }
}

// ================================================================= resources

final class ResourcesPage extends ConsumerWidget {
  const ResourcesPage({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [Resource? existing]) async {
    final orgId = ref.read(currentOrgIdProvider);
    if (orgId == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ResourceDialog(orgId: orgId, existing: existing),
    );
    if (saved ?? false) ref.invalidate(workspaceResourcesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminPage(
      title: 'Benches & machines',
      subtitle:
          'What a stage completion is credited to on the timeline — "Completed by PR-02", '
          '"Bench 4".',
      actions: [
        FilledButton.icon(
          onPressed: () => _edit(context, ref),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add'),
        ),
      ],
      children: [
        AsyncBody<List<Resource>>(
          value: ref.watch(workspaceResourcesProvider),
          what: 'The list',
          onRetry: () => ref.invalidate(workspaceResourcesProvider),
          builder: (rows) => AdminTable<Resource>(
            rows: rows,
            onTap: (r) => _edit(context, ref, r),
            emptyTitle: 'Nothing yet',
            emptyMessage: 'Add a bench, printer or furnace.',
            columns: [
              AdminColumn(
                'Code',
                (c, r) => Text(r.code, style: AppTheme.mono(size: 13, color: c.scheme.onSurface)),
                flex: 2,
              ),
              AdminColumn('Name', (c, r) => Text(r.label), flex: 4),
              AdminColumn('Stage', (c, r) => Text(r.stage?.label ?? 'Any'), flex: 2),
              AdminColumn(
                'Status',
                (c, r) => r.isActive
                    ? const StatusChip(
                        label: 'In use',
                        tone: ChipTone.success,
                        dense: true,
                        dot: true,
                      )
                    : const StatusChip(label: 'Retired', dense: true),
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

final class _ResourceDialog extends ConsumerStatefulWidget {
  const _ResourceDialog({required this.orgId, this.existing});

  final String orgId;
  final Resource? existing;

  @override
  ConsumerState<_ResourceDialog> createState() => _ResourceDialogState();
}

class _ResourceDialogState extends ConsumerState<_ResourceDialog> {
  final _form = GlobalKey<FormState>();
  late final _code = TextEditingController(text: widget.existing?.code);
  late final _label = TextEditingController(text: widget.existing?.label);
  late LifecycleStage? _stage = widget.existing?.stage;
  late bool _active = widget.existing?.isActive ?? true;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .saveResource(
            id: widget.existing?.id,
            orgId: widget.orgId,
            code: _code.text,
            label: _label.text,
            stage: _stage,
            isActive: _active,
          );
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) showAdminError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.existing == null ? 'Add a bench or machine' : 'Edit ${widget.existing!.code}',
    ),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              style: AppTheme.mono(size: 15, color: context.scheme.onSurface),
              decoration: const InputDecoration(labelText: 'Code', hintText: 'BENCH-5'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a short code.' : null,
            ),
            const SizedBox(height: Spacing.md),
            TextFormField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'Setting Bench 5'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name.' : null,
            ),
            const SizedBox(height: Spacing.md),
            DropdownButtonFormField<LifecycleStage?>(
              initialValue: _stage,
              decoration: const InputDecoration(labelText: 'Stage it serves'),
              items: [
                const DropdownMenuItem<LifecycleStage?>(value: null, child: Text('Any stage')),
                for (final s in LifecycleStage.values)
                  DropdownMenuItem<LifecycleStage?>(value: s, child: Text(s.label)),
              ],
              onChanged: (s) => setState(() => _stage = s),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('In use'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
    ],
  );
}
