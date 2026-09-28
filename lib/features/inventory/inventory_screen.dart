/// The vault.
///
/// `inventory_management` is the one screen in the corpus that shipped **no JavaScript at all**.
/// Its search box filtered nothing, its filter icon opened nothing, its "Assign" button did
/// nothing, and both of its stock bars were `width: 62%` written into the markup. Everything it
/// painted is real here.
///
/// It also, without saying so, drew **two different stock models in one list**: a gold row with a
/// bar and a gram figure, and a diamond row with a grade summary and no bar. That is the right
/// distinction and it is load-bearing — metal is a bulk balance measured against a reorder
/// threshold, a serialised stone is a unique object that is either in the vault or committed to a
/// job. So the segmented control at the top of this screen is not a filter, it is a choice of
/// which model you are looking at, and the facets change with it.
///
/// The third thing it proved by accident: its diamond row showed CARAT / COLOR / CLARITY while its
/// ruby row showed CARAT / CUT / ORIGIN. Gem attributes are species-typed, so they are rendered
/// from `InventoryItem.attrs` per species and never from a fixed 4C table (see
/// [SpeciesAttributes]).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/inventory/allocate_sheet.dart';
import 'package:dhanaos/features/inventory/goods_in_screen.dart';
import 'package:dhanaos/features/inventory/inventory_gateway.dart';
import 'package:dhanaos/features/inventory/inventory_widgets.dart';
import 'package:dhanaos/features/inventory/item_screen.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // The filter controller is keepAlive, so a keeper coming back from an item finds their own
    // search term still in the box.
    final existing = ref.read(vaultFilterControllerProvider).search;
    if (existing != null) _search.text = existing;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// A keystroke is not a query. 300ms is one round trip for "DIA-99" and still reads as
  /// search-as-you-type.
  void _onSearchChanged(String value) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) ref.read(vaultFilterControllerProvider.notifier).setSearch(value);
    });
  }

  void _commitSearch(String value) {
    _debounce?.cancel();
    ref.read(vaultFilterControllerProvider.notifier).setSearch(value);
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(vaultFilterControllerProvider);
    final page = ref.watch(vaultPageProvider(filter));
    final permissions = ref.watch(permissionsProvider);
    final canMove = permissions.canMoveStock;

    return Scaffold(
      backgroundColor: context.scheme.surface,
      floatingActionButton: canMove
          ? FloatingActionButton.extended(
              // Absent from every mockup, and the most consequential act in this area: the shop
              // taking a client's own stone into its care.
              onPressed: () => unawaited(_startGoodsIn(context)),
              icon: const Icon(Icons.assignment_turned_in_outlined),
              label: const Text('Client goods in'),
            )
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.md,
              Spacing.md,
              Spacing.sm,
            ),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: _onSearchChanged,
              onSubmitted: _commitSearch,
              decoration: InputDecoration(
                hintText: 'Stock code or description',
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear the search',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          _debounce?.cancel();
                          _search.clear();
                          ref.read(vaultFilterControllerProvider.notifier).setSearch(null);
                          setState(() {});
                        },
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: DhSegmented<StockKind?>(
              value: filter.kind,
              onChanged: ref.read(vaultFilterControllerProvider.notifier).setKind,
              // Explicit type argument: the "All" segment carries a null value, and the list is
              // const, so the element type has to be stated rather than inferred from the first
              // entry.
              segments: const <DhSegment<StockKind?>>[
                DhSegment(value: StockKind.metalBulk, label: 'Metal', icon: Icons.layers_outlined),
                DhSegment(
                  value: StockKind.stoneSerialized,
                  label: 'Stones',
                  icon: Icons.diamond_outlined,
                ),
                DhSegment(
                  value: StockKind.consumable,
                  label: 'Supplies',
                  icon: Icons.handyman_outlined,
                ),
                DhSegment(value: null, label: 'All'),
              ],
            ),
          ),
          const SizedBox(height: Spacing.sm),
          _FacetBar(filter: filter),
          _ResultHeader(filter: filter, page: page),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(vaultPageProvider(filter)),
              child: switch (page) {
                AsyncValue(value: final loaded?) => _body(context, loaded, canMove: canMove),
                AsyncError(error: final error) => ListView(
                    children: [
                      SizedBox(height: MediaQuery.sizeOf(context).height * 0.12),
                      ErrorState(
                        title: 'The vault list did not load',
                        message: error is DhFailure
                            ? error.message
                            : 'Check the connection and pull down to try again.',
                        detail: error is DhFailure ? error.detail : null,
                        onRetry: () => ref.invalidate(vaultPageProvider(filter)),
                      ),
                    ],
                  ),
                _ => const Padding(
                    padding: EdgeInsets.all(Spacing.md),
                    child: LoadingSkeleton.list(count: 5),
                  ),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, VaultPage page, {required bool canMove}) {
    if (page.isEmpty) {
      return ListView(
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * 0.10),
          if (page.filter.isNarrowed)
            EmptyState(
              icon: Icons.filter_alt_off_outlined,
              title: 'Nothing in the vault matches',
              message: page.filter.hasSearch
                  ? 'No stock code or description matches "${page.filter.search}" with these '
                      'filters on. Search by tray code — AU-750, DIA-9982-A.'
                  : 'No stock of that description is on the shelf. Widen the filter, or receive '
                      'a parcel to put some there.',
              actionLabel: 'Clear the filters',
              onAction: () => ref.read(vaultFilterControllerProvider.notifier).clearFacets(),
            )
          else
            EmptyState(
              icon: Icons.inventory_2_outlined,
              title: _emptyTitle(page.filter.kind),
              message: 'A stock item starts at zero and is filled by a Receive movement, so the '
                  'balance always has a row explaining where it came from.',
            ),
        ],
      );
    }

    final lowStock = page.filter.needsReorderOnly ? const <InventoryItem>[] : page.lowStock;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.sm, Spacing.md, Spacing.xxl + 40),
      itemCount: page.items.length + (lowStock.isEmpty ? 0 : 1),
      separatorBuilder: (_, __) => const SizedBox(height: Spacing.sm + Spacing.xs),
      itemBuilder: (context, index) {
        if (lowStock.isNotEmpty && index == 0) {
          return VaultNote(
            tone: VaultNoteTone.risk,
            icon: Icons.trending_down_rounded,
            text: lowStock.length == 1
                ? '${lowStock.first.code} is at or below its reorder level '
                    '(${lowStock.first.quantityLabel} on hand).'
                : '${lowStock.length} items are at or below their reorder level.',
            action: TextButton(
              onPressed: () => ref
                  .read(vaultFilterControllerProvider.notifier)
                  .setNeedsReorderOnly(value: true),
              child: const Text('Show them'),
            ),
          );
        }
        final item = page.items[index - (lowStock.isEmpty ? 0 : 1)];
        return StockRowCard(
          item: item,
          onTap: () => unawaited(openItem(context, item.id)),
          // The button the mockup implied and never wired. Shut for a keeper without the role,
          // and shut when there is nothing free to commit — with the reason on the row itself.
          onAssign: canMove && item.qtyAvailable > 0
              ? () => unawaited(showAllocateSheet(context, item: item))
              : null,
        );
      },
    );
  }

  static String _emptyTitle(StockKind? kind) => switch (kind) {
        StockKind.metalBulk => 'No metal on the shelf',
        StockKind.stoneSerialized => 'No stones in the vault',
        StockKind.consumable => 'No supplies recorded',
        null => 'The vault is empty',
      };

  /// Goods-in is always about a job — the client is bringing their stone in *for* something. So
  /// the flow picks the job first rather than asking for a name into a box.
  Future<void> _startGoodsIn(BuildContext context) async {
    final job = await pickJobSheet(
      context,
      title: 'Whose job is this for?',
      blurb: 'Custody is recorded against a committed job, so the bench and the client see the '
          'same receipt.',
    );
    if (job == null || !context.mounted) return;
    await openGoodsIn(context, job.id);
  }
}

// ================================================================= header

final class _ResultHeader extends ConsumerWidget {
  const _ResultHeader({required this.filter, required this.page});

  final VaultFilter filter;
  final AsyncValue<VaultPage> page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loaded = page.value;
    final count = loaded?.items.length;
    // The repository pages with `limit`, so a full page means "at least this many".
    final capped = count != null && count >= filter.limit;
    final value = loaded?.pageValue;
    // Some items carry no unit cost, so the total is a floor rather than the figure. Saying so is
    // the difference between a number an accountant can use and one they cannot.
    final partial = loaded?.valueIsPartial ?? false;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.xs, Spacing.md, Spacing.sm),
      child: Row(
        children: [
          Text(
            count == null
                ? 'Loading'
                : '$count${capped ? '+' : ''} ${count == 1 ? 'item' : 'items'}',
            style: AppTheme.mono(
              size: 11.5,
              weight: FontWeight.w600,
              color: context.scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          if (value != null)
            Tooltip(
              message: partial
                  ? 'Value of the priced items on this page. Some items carry no unit cost, so '
                      'the real figure is higher.'
                  : 'Value on hand across this page, at the recorded unit costs.',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (partial)
                    Padding(
                      padding: const EdgeInsets.only(right: Spacing.xs),
                      child: Icon(
                        Icons.info_outline_rounded,
                        size: 13,
                        color: context.scheme.onSurfaceVariant,
                      ),
                    ),
                  Text(
                    value.format(compact: true),
                    style: AppTheme.mono(
                      size: 12,
                      weight: FontWeight.w600,
                      color: context.scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ================================================================= facets

/// The filter icon that had nothing behind it.
///
/// The facets offered depend on which stock model is on screen: asking a gold parcel for its
/// clarity grade is how a filter row becomes noise. Origin is always offered for stones (D-012) —
/// a lab-grown line must never be satisfied out of a natural parcel, and this is where an
/// operator asks the vault that question.
final class _FacetBar extends ConsumerWidget {
  const _FacetBar({required this.filter});

  final VaultFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(vaultFilterControllerProvider.notifier);
    final active = filter.activeFacets;
    final isMetal = filter.kind == StockKind.metalBulk;
    final isStone = filter.kind == StockKind.stoneSerialized;

    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        children: [
          if (active > 0) ...[
            ActionChip(
              avatar: const Icon(Icons.close_rounded, size: 16),
              label: Text('Clear $active'),
              onPressed: notifier.clearFacets,
            ),
            const SizedBox(width: Spacing.sm),
          ],
          if (isMetal) ...[
            _PickerChip(
              label: filter.baseMetal?.label ?? 'Alloy',
              selected: filter.baseMetal != null,
              onTap: () => unawaited(
                _pick<BaseMetal>(
                  context,
                  title: 'Filter by alloy',
                  subtitle: 'Purity follows the alloy — 22K rose gold is not a product.',
                  values: BaseMetal.values,
                  selected: filter.baseMetal,
                  labelOf: (metal) => metal.label,
                  onPicked: notifier.setBaseMetal,
                ),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            _PickerChip(
              label: filter.purity?.label ?? 'Purity',
              selected: filter.purity != null,
              onTap: () => unawaited(
                _pick<MetalPurity>(
                  context,
                  title: 'Filter by purity',
                  subtitle: filter.baseMetal == null
                      ? 'Every purity the workshop stocks.'
                      : 'The purities ${filter.baseMetal!.label.toLowerCase()} comes in.',
                  // D-012: the mockups shipped a flat purity list with no dependency on the
                  // alloy, which made 22K rose gold selectable.
                  values: filter.baseMetal?.purities ?? MetalPurity.values,
                  selected: filter.purity,
                  labelOf: (purity) => purity.label,
                  onPicked: notifier.setPurity,
                ),
              ),
            ),
            const SizedBox(width: Spacing.sm),
          ],
          if (isStone) ...[
            _PickerChip(
              label: filter.stoneType?.label ?? 'Species',
              selected: filter.stoneType != null,
              onTap: () => unawaited(
                _pick<StoneType>(
                  context,
                  title: 'Filter by species',
                  subtitle: 'Diamond and moissanite are graded on the 4Cs; coloured stones are '
                      'not, which is why their attributes differ.',
                  values: StoneType.values,
                  selected: filter.stoneType,
                  labelOf: (type) => type.label,
                  onPicked: notifier.setStoneType,
                ),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            for (final origin in StoneOrigin.values) ...[
              FilterChip(
                avatar: Icon(
                  origin == StoneOrigin.natural
                      ? Icons.terrain_rounded
                      : Icons.science_outlined,
                  size: 16,
                ),
                label: Text(origin.label),
                selected: filter.origin == origin,
                onSelected: (on) => notifier.setOrigin(on ? origin : null),
              ),
              const SizedBox(width: Spacing.sm),
            ],
            _PickerChip(
              label: filter.shape?.label ?? 'Shape',
              selected: filter.shape != null,
              onTap: () => unawaited(
                _pick<StoneShape>(
                  context,
                  title: 'Filter by shape',
                  subtitle: 'The cut outline, as the tray label reads it.',
                  values: StoneShape.values,
                  selected: filter.shape,
                  labelOf: (shape) => shape.label,
                  onPicked: notifier.setShape,
                ),
              ),
            ),
            const SizedBox(width: Spacing.sm),
          ],
          FilterChip(
            avatar: const Icon(Icons.check_circle_outline_rounded, size: 16),
            label: const Text('Free stock only'),
            selected: filter.inStockOnly,
            onSelected: (value) => notifier.setInStockOnly(value: value),
          ),
          const SizedBox(width: Spacing.sm),
          FilterChip(
            avatar: const Icon(Icons.trending_down_rounded, size: 16),
            label: const Text('Below reorder'),
            selected: filter.needsReorderOnly,
            onSelected: (value) => notifier.setNeedsReorderOnly(value: value),
          ),
          const SizedBox(width: Spacing.md),
        ],
      ),
    );
  }

  /// One-of-many, with "Any" at the top. Writes through as the row is tapped and closes, because
  /// a single choice needs no Done button.
  Future<void> _pick<T extends Object>(
    BuildContext context, {
    required String title,
    required String subtitle,
    required List<T> values,
    required T? selected,
    required String Function(T) labelOf,
    required void Function(T?) onPicked,
  }) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: sheetContext.text.headlineSmall),
                      const SizedBox(height: Spacing.xs),
                      Text(
                        subtitle,
                        style: sheetContext.text.bodySmall
                            ?.copyWith(color: sheetContext.scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      _OptionRow(
                        label: 'Any',
                        selected: selected == null,
                        onTap: () {
                          onPicked(null);
                          Navigator.of(sheetContext).pop();
                        },
                      ),
                      for (final value in values)
                        _OptionRow(
                          label: labelOf(value),
                          selected: value == selected,
                          onTap: () {
                            onPicked(value);
                            Navigator.of(sheetContext).pop();
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Spacing.md),
              ],
            ),
          ),
        ),
      );
}

/// One row of a one-of-many sheet. A check where the radio would be: the chosen state has to be
/// visible at a glance in a list of twelve shapes, and the sheet closes on the tap anyway.
final class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        onTap: onTap,
        selected: selected,
        title: Text(label),
        trailing: selected
            ? Icon(Icons.check_rounded, size: 20, color: context.scheme.secondary)
            : null,
      );
}

final class _PickerChip extends StatelessWidget {
  const _PickerChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FilterChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        avatar: const Icon(Icons.expand_more_rounded, size: 16),
        onSelected: (_) => onTap(),
      );
}
