/// Who the piece is for.
///
/// D-004 makes this more than a label: the customer's GSTIN decides whether the invoice splits
/// into CGST + SGST or charges IGST, and `customers.currency` is why a US retailer's job can be
/// quoted in dollars against an INR workshop. A job order with no customer cannot be invoiced, so
/// step 2 gates on it.
///
/// The sheet can create a retailer without leaving the wizard. The alternative is a dead end at
/// 7pm when a walk-in order arrives and the customer record does not exist yet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/customer_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// Opens the picker. Returns the chosen retailer, or null if the operator backed out.
Future<Customer?> pickCustomer(BuildContext context, {String? selectedId}) {
  return showModalBottomSheet<Customer>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: FractionallySizedBox(
        heightFactor: 0.9,
        child: _CustomerSheet(selectedId: selectedId),
      ),
    ),
  );
}

final class _CustomerSheet extends ConsumerStatefulWidget {
  const _CustomerSheet({this.selectedId});

  final String? selectedId;

  @override
  ConsumerState<_CustomerSheet> createState() => _CustomerSheetState();
}

class _CustomerSheetState extends ConsumerState<_CustomerSheet> {
  final _search = TextEditingController();
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _contact = TextEditingController();
  final _gstin = TextEditingController();

  bool _creating = false;
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    _name.dispose();
    _code.dispose();
    _contact.dispose();
    _gstin.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showFailure(context, 'Enter the retailer\'s name before saving them.');
      return;
    }
    setState(() => _busy = true);
    try {
      final created = await ref.read(customerRepositoryProvider).createCustomer(
            name: name,
            code: _code.text,
            contactName: _contact.text,
            gstin: _gstin.text,
          );
      ref.invalidate(customerDirectoryProvider);
      if (!mounted) return;
      Navigator.of(context).pop(created);
    } on DhFailure catch (failure) {
      if (!mounted) return;
      setState(() => _busy = false);
      showFailure(context, failure.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final directory = ref.watch(customerDirectoryProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _creating ? 'New retailer' : 'Who is this for?',
                  style: context.text.headlineSmall?.copyWith(color: context.scheme.onSurface),
                ),
              ),
              TextButton.icon(
                onPressed: _busy ? null : () => setState(() => _creating = !_creating),
                icon: Icon(_creating ? Icons.search_rounded : Icons.person_add_alt_outlined),
                label: Text(_creating ? 'Search instead' : 'New retailer'),
              ),
            ],
          ),
          const Gap.sm(),
          if (_creating)
            Expanded(child: _buildCreateForm(context))
          else
            Expanded(child: _buildDirectory(context, directory)),
        ],
      ),
    );
  }

  Widget _buildCreateForm(BuildContext context) {
    return ListView(
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Retailer name',
            hintText: 'Scottsdale Diamond Co.',
          ),
        ),
        const Gap.md(),
        TextField(
          controller: _code,
          textCapitalization: TextCapitalization.characters,
          style: AppTheme.mono(size: 14, color: context.scheme.onSurface),
          decoration: const InputDecoration(
            labelText: 'Short code (optional)',
            hintText: 'SDC',
          ),
        ),
        const Gap.md(),
        TextField(
          controller: _contact,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Contact person (optional)',
            hintText: 'Priya Raval',
          ),
        ),
        const Gap.md(),
        TextField(
          controller: _gstin,
          textCapitalization: TextCapitalization.characters,
          style: AppTheme.mono(size: 14, color: context.scheme.onSurface),
          decoration: const InputDecoration(
            labelText: 'GSTIN (optional)',
            hintText: '24ABCDE1234F1Z5',
            helperText: 'Needed before a tax invoice can be raised, and it decides whether the '
                'supply is CGST + SGST or IGST.',
            helperMaxLines: 3,
          ),
        ),
        const Gap.lg(),
        FilledButton.icon(
          onPressed: _busy ? null : _create,
          icon: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded),
          label: const Text('Save retailer and use them'),
        ),
      ],
    );
  }

  Widget _buildDirectory(BuildContext context, AsyncValue<List<Customer>> directory) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'Search by name or code',
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
        const Gap.md(),
        Expanded(
          child: directory.when(
            loading: () => const LoadingSkeleton.list(count: 5),
            error: (error, _) => ErrorState(
              compact: true,
              title: 'The retailer list did not load',
              message: error is DhFailure
                  ? error.message
                  : 'DhanaOS could not read the customer directory.',
              onRetry: () => ref.invalidate(customerDirectoryProvider),
              secondaryLabel: 'Add a new retailer',
              onSecondary: () => setState(() => _creating = true),
            ),
            data: (all) {
              final matches = _filter(all);
              if (matches.isEmpty) {
                return EmptyState(
                  compact: true,
                  icon: Icons.storefront_outlined,
                  title: all.isEmpty ? 'No retailers yet' : 'Nothing matches that',
                  message: all.isEmpty
                      ? 'Add the retailer this order came from and it will be on the list next '
                          'time.'
                      : 'No retailer matches "${_search.text.trim()}". Check the spelling, or add '
                          'them as a new record.',
                  actionLabel: 'Add a new retailer',
                  onAction: () => setState(() => _creating = true),
                );
              }
              return ListView.separated(
                itemCount: matches.length,
                separatorBuilder: (_, __) => const SizedBox(height: Spacing.sm),
                itemBuilder: (itemContext, index) {
                  final customer = matches[index];
                  return SelectableTile(
                    title: customer.name,
                    blurb: _blurbFor(customer),
                    icon: Icons.storefront_outlined,
                    selected: customer.id == widget.selectedId,
                    inGroup: true,
                    badge: customer.isGstRegistered
                        ? null
                        : const StatusChip(
                            label: 'No GSTIN',
                            tone: ChipTone.warning,
                            dense: true,
                          ),
                    onTap: () => Navigator.of(itemContext).pop(customer),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  List<Customer> _filter(List<Customer> all) {
    final term = _search.text.trim().toLowerCase();
    if (term.isEmpty) return all;
    return [
      for (final c in all)
        if (c.name.toLowerCase().contains(term) ||
            (c.code?.toLowerCase().contains(term) ?? false) ||
            (c.contactName?.toLowerCase().contains(term) ?? false))
          c,
    ];
  }

  static String _blurbFor(Customer customer) {
    final parts = <String>[
      if (customer.code?.trim().isNotEmpty ?? false) customer.code!.trim(),
      customer.currency,
      if (customer.contactName?.trim().isNotEmpty ?? false) customer.contactName!.trim(),
    ];
    return parts.join(' · ');
  }
}
