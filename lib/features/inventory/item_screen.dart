/// One line of stock, in full: what it is, where it is, what it is worth, who is holding it and
/// every movement it has ever made.
///
/// The mockup's stock row had a name, a bar at a fixed width and an Assign button that did
/// nothing. There was no detail screen at all — no certificate, no vault location, no history —
/// which is why its own dashboard could raise "Melee diamonds count mismatch at receiving" with
/// nowhere for an operator to go and look.
///
/// Three things on this screen exist because of that gap:
///
///   * **The ledger.** `stock_transactions` is append-only, so this list *is* the balance above
///     it. Nothing else in the app can explain a quantity.
///   * **The reconciliation block.** Received, issued, returned, scrapped and the signed
///     adjustment, with loss as a share of everything received. That is the figure a month-end
///     argues about.
///   * **Origin, always.** D-012: `stone_origin` survived in exactly one of 46 mockups. A stone
///     with no origin recorded says so in red rather than showing an empty cell.
library;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/inventory/allocate_sheet.dart';
import 'package:dhanaos/features/inventory/inventory_actions.dart';
import 'package:dhanaos/features/inventory/inventory_gateway.dart';
import 'package:dhanaos/features/inventory/inventory_widgets.dart';
import 'package:dhanaos/features/inventory/stock_txn_sheet.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// Open one stock item. Pushed rather than routed: the vault list keeps its scroll position and
/// its filters behind it, which is what a keeper working a tray expects.
Future<void> openItem(BuildContext context, String itemId) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ItemScreen(itemId: itemId)),
    );

final class ItemScreen extends ConsumerWidget {
  const ItemScreen({super.key, required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(itemDetailProvider(itemId));

    return Scaffold(
      backgroundColor: context.scheme.surface,
      appBar: AppBar(
        title: Text(
          detail.value?.item.code ?? 'Stock item',
          style: AppTheme.mono(size: 15, weight: FontWeight.w600, color: context.scheme.onSurface),
        ),
        actions: [
          IconButton(
            tooltip: 'Re-read from the vault',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref.invalidate(itemDetailProvider(itemId)),
          ),
        ],
      ),
      bottomNavigationBar: switch (detail) {
        AsyncValue(value: final loaded?) => _Actions(detail: loaded),
        _ => null,
      },
      body: switch (detail) {
        AsyncValue(value: final loaded?) => _Body(detail: loaded),
        AsyncError(error: final error) => ErrorState(
            title: 'This item did not load',
            message: error is DhFailure
                ? error.message
                : 'Check the connection and try again.',
            detail: error is DhFailure ? error.detail : null,
            onRetry: () => ref.invalidate(itemDetailProvider(itemId)),
          ),
        _ => const Padding(
            padding: EdgeInsets.all(Spacing.md),
            child: Column(
              children: [
                LoadingSkeleton.card(),
                SizedBox(height: Spacing.md),
                LoadingSkeleton.list(count: 2),
              ],
            ),
          ),
      },
    );
  }
}

// ================================================================= body

final class _Body extends ConsumerWidget {
  const _Body({required this.detail});

  final ItemDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = detail.item;
    final canMove = ref.watch(permissionsProvider).canMoveStock;

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(itemDetailProvider(item.id)),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.lg),
        children: [
          _Identity(detail: detail),
          const SizedBox(height: Spacing.md),
          _Balance(item: item),
          const SizedBox(height: Spacing.md),
          DhSectionCard(
            title: item.isBulkMetal ? 'Alloy' : 'Stone attributes',
            subtitle: item.isSerialized
                ? 'Read per species: a diamond is graded on colour and clarity, a ruby on cut and '
                    'treatment.'
                : null,
            leading: Icon(item.isBulkMetal ? Icons.layers_outlined : Icons.diamond_outlined),
            child: SpeciesAttributes(item: item),
          ),
          if (item.isSerialized) ...[
            const SizedBox(height: Spacing.md),
            _Certificate(detail: detail),
          ],
          const SizedBox(height: Spacing.md),
          _Reconciliation(detail: detail),
          const SizedBox(height: Spacing.md),
          _Reservations(detail: detail, canMove: canMove),
          const SizedBox(height: Spacing.md),
          _Ledger(detail: detail),
        ],
      ),
    );
  }
}

// ================================================================= identity

final class _Identity extends StatelessWidget {
  const _Identity({required this.detail});

  final ItemDetail detail;

  @override
  Widget build(BuildContext context) {
    final item = detail.item;
    final url = detail.photoUrl;

    return DhCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (url != null) ...[
                ClipRRect(
                  borderRadius: Radii.rMd,
                  child: CachedNetworkImage(
                    imageUrl: url,
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                    errorWidget: (context, _, __) => Container(
                      width: 72,
                      height: 72,
                      color: context.dh.surfaceContainerHigh,
                      child: Icon(
                        Icons.image_not_supported_outlined,
                        size: 20,
                        color: context.scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        StatusChip.code(item.code, dense: true),
                        const SizedBox(width: Spacing.sm),
                        StatusChip(label: item.kind.label, dense: true),
                      ],
                    ),
                    const SizedBox(height: Spacing.sm),
                    Text(item.label, style: context.text.headlineSmall),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      item.gradeSummary,
                      style: AppTheme.mono(size: 12, color: context.scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          DataPairGrid(
            children: [
              DataPair.mono(
                label: 'Vault location',
                value: item.location ?? DataPair.placeholder,
                icon: Icons.place_outlined,
                tooltip: 'Where the tray actually is. An item with no location is an item somebody '
                    'has to hunt for.',
              ),
              DataPair.mono(
                label: 'Lot reference',
                value: item.lotRef ?? DataPair.placeholder,
              ),
              DataPair.mono(
                label: 'Supplier',
                value: detail.supplierName(item.supplierId) ?? DataPair.placeholder,
              ),
              DataPair.timestamp(label: 'On the books since', utc: item.createdAt, withTime: false),
            ],
          ),
        ],
      ),
    );
  }
}

// ================================================================= balance

final class _Balance extends StatelessWidget {
  const _Balance({required this.item});

  final InventoryItem item;

  @override
  Widget build(BuildContext context) {
    final cost = item.unitCost;
    final value = item.onHandValue;

    return DhSectionCard(
      title: 'Stock',
      leading: const Icon(Icons.inventory_2_outlined),
      accent: item.needsReorder ? context.scheme.error : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DataPairGrid(
            children: [
              DataPair.mono(
                label: 'On hand',
                value: item.quantityLabel,
                emphasis: DataEmphasis.display,
                valueColor: item.needsReorder ? context.scheme.error : null,
              ),
              DataPair.mono(label: 'Committed', value: qtyLabel(item.qtyAllocated, item.uom)),
              DataPair.mono(
                label: 'Free',
                value: item.availableLabel,
                emphasis: DataEmphasis.strong,
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          // The bar the mockup hardcoded at 62%. For a serialised stone there is nothing to
          // measure — it is one object — so the state is stated in words instead.
          if (item.isBulkMetal)
            StockBar(item: item)
          else
            VaultNote(
              tone: item.isInStock ? VaultNoteTone.good : VaultNoteTone.info,
              text: item.isInStock
                  ? 'In the vault and free to commit.'
                  : 'Committed to a job. Release the reservation to free it.',
            ),
          const SizedBox(height: Spacing.md),
          DataPairGrid(
            children: [
              DataPair.mono(
                label: item.isSerialized ? 'Cost' : 'Unit cost',
                value: cost == null
                    ? DataPair.placeholder
                    : item.isSerialized
                        ? cost.format()
                        : '${cost.format()} / ${item.uom.symbol}',
                tooltip: cost == null
                    ? 'No unit cost recorded. Enter it on the next Receive and every job using '
                        'this stock can be valued.'
                    : null,
              ),
              DataPair.mono(
                label: 'Value on hand',
                value: moneyOrDash(value),
                emphasis: DataEmphasis.strong,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ================================================================= certificate

final class _Certificate extends StatelessWidget {
  const _Certificate({required this.detail});

  final ItemDetail detail;

  @override
  Widget build(BuildContext context) {
    final item = detail.item;
    final file = detail.certificate;
    final url = detail.certificateUrl;
    final lab = item.certLab;

    return DhSectionCard(
      title: 'Certification',
      leading: const Icon(Icons.verified_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DataPairGrid(
            children: [
              DataPair.mono(label: 'Lab', value: lab?.label ?? DataPair.placeholder),
              DataPair.mono(
                label: 'Report number',
                value: item.certNumber ?? DataPair.placeholder,
              ),
            ],
          ),
          if (lab == null || lab.skipsStage) ...[
            const SizedBox(height: Spacing.md),
            const VaultNote(
              text: 'No certificate on file. For a natural stone that is a valuation question, '
                  'and for a lab-grown one it is a disclosure question.',
            ),
          ],
          if (file != null) ...[
            const SizedBox(height: Spacing.md),
            AttachmentTile.row(
              item: AttachmentView(
                id: file.id,
                kind: file.kind,
                filename: file.filename,
                meta: file.metaLabel,
              ),
              onOpen: url == null ? null : () => unawaited(_showLink(context, file, url)),
            ),
          ],
        ],
      ),
    );
  }

  /// A signed link, shown rather than opened — the same treatment certification uses. A public
  /// URL to a grading report outlives the stone, the job and the customer relationship.
  Future<void> _showLink(BuildContext context, Attachment file, String url) => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            file.filename,
            style: AppTheme.mono(size: 13, color: dialogContext.scheme.onSurface),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Copy this link into a browser to read the report. It stops working in thirty '
                'minutes, so it is safe to lose and not safe to forward.',
                style: dialogContext.text.bodySmall,
              ),
              const SizedBox(height: Spacing.md),
              SelectableText(
                url,
                style: AppTheme.mono(size: 11, color: dialogContext.scheme.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
}

// ================================================================= reconciliation

/// The five figures that decide whether the balance is believable.
final class _Reconciliation extends StatelessWidget {
  const _Reconciliation({required this.detail});

  final ItemDetail detail;

  @override
  Widget build(BuildContext context) {
    final uom = detail.item.uom;
    final ratio = detail.lossRatio;

    return DhSectionCard(
      title: 'Reconciliation',
      subtitle: 'Every figure here is a sum over the ledger below, not a stored number.',
      leading: const Icon(Icons.balance_rounded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DataPairGrid(
            columns: 3,
            children: [
              DataPair.mono(label: 'Received', value: qtyLabel(detail.received, uom)),
              DataPair.mono(label: 'Issued', value: qtyLabel(detail.issued, uom)),
              DataPair.mono(label: 'Returned', value: qtyLabel(detail.returned, uom)),
              DataPair.mono(
                label: 'Scrapped',
                value: qtyLabel(detail.scrapped, uom),
                valueColor: detail.scrapped > 0 ? context.scheme.error : null,
              ),
              DataPair.mono(
                label: 'Adjusted',
                value: signedQtyLabel(detail.adjusted, uom),
                valueColor: detail.adjusted < 0 ? context.scheme.error : null,
              ),
              DataPair.mono(
                label: 'Loss of receipts',
                value: ratio == null ? DataPair.placeholder : '${(ratio * 100).toStringAsFixed(1)}%',
                tooltip: 'Scrap plus shortfalls, against everything ever received. Filings and '
                    'sprues are real and weighable — a shop that cannot see this figure writes '
                    'the difference off as shrinkage.',
              ),
            ],
          ),
          if (detail.hasLoss) ...[
            const SizedBox(height: Spacing.md),
            VaultNote(
              tone: VaultNoteTone.risk,
              icon: Icons.delete_sweep_outlined,
              text: detail.adjusted < 0
                  ? 'A stock-take has found ${qtyLabel(-detail.adjusted, uom)} less than the '
                      'books. Read the adjustment note in the ledger before ordering more.'
                  : '${qtyLabel(detail.scrapped, uom)} has been booked as scrap. Pair it with the '
                      'bench weights on the jobs to see where it went.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= reservations

final class _Reservations extends ConsumerWidget {
  const _Reservations({required this.detail, required this.canMove});

  final ItemDetail detail;
  final bool canMove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = detail.openAllocations;
    final busy = ref.watch(inventoryActionsProvider) != null;

    return DhSectionCard(
      title: 'Who is holding it',
      subtitle: open.isEmpty
          ? null
          : 'Reserved stock is still on the shelf. Issuing is what takes it off the balance.',
      leading: const Icon(Icons.bookmark_border_rounded),
      child: open.isEmpty
          ? const EmptyState(
              compact: true,
              icon: Icons.bookmark_border_rounded,
              title: 'No reservations',
              message: 'Nothing is committed to a job. Assign stock and the job appears here.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final allocation in open) ...[
                  AllocationRow(
                    allocation: allocation,
                    uom: detail.item.uom,
                    jobCode: detail.jobCode(allocation.jobId),
                    actorName: detail.personName(allocation.allocatedBy),
                    busy: busy,
                    onIssue: canMove && allocation.isReservedOnly
                        ? () => unawaited(_issue(context, ref, allocation))
                        : null,
                    onRelease: canMove && allocation.isReservedOnly
                        ? () => unawaited(_release(context, ref, allocation))
                        : null,
                  ),
                  const SizedBox(height: Spacing.sm),
                ],
              ],
            ),
    );
  }

  /// Issuing posts an append-only movement, so it is confirmed. Releasing does not move stock at
  /// all, so it is not.
  Future<void> _issue(
    BuildContext context,
    WidgetRef ref,
    StockAllocation allocation,
  ) async {
    final code = detail.jobCode(allocation.jobId);
    final agreed = await confirmAction(
      context,
      title: 'Issue ${qtyLabel(allocation.qty, detail.item.uom)} to $code?',
      message: 'This takes the stock out of the vault and onto the job. The movement joins the '
          'permanent ledger — if it comes back, that is a Return, not an edit.',
      confirmLabel: 'Issue from vault',
    );
    if (!agreed || !context.mounted) return;
    try {
      await ref.read(inventoryActionsProvider.notifier).issue(allocation);
      if (!context.mounted) return;
      showDone(context, '${qtyLabel(allocation.qty, detail.item.uom)} issued to $code.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _release(
    BuildContext context,
    WidgetRef ref,
    StockAllocation allocation,
  ) async {
    try {
      await ref.read(inventoryActionsProvider.notifier).release(allocation);
      if (!context.mounted) return;
      showDone(
        context,
        '${qtyLabel(allocation.qty, detail.item.uom)} released back to free stock.',
      );
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }
}

// ================================================================= ledger

final class _Ledger extends StatelessWidget {
  const _Ledger({required this.detail});

  final ItemDetail detail;

  @override
  Widget build(BuildContext context) {
    final rows = detail.ledger;

    return DhSectionCard(
      title: 'Movement history',
      subtitle: 'Append-only. UPDATE and DELETE are revoked in Postgres, so this is the whole '
          'truth about the balance.',
      leading: const Icon(Icons.receipt_long_outlined),
      child: rows.isEmpty
          ? const EmptyState(
              compact: true,
              icon: Icons.receipt_long_outlined,
              title: 'No movement yet',
              message: 'A stock item starts at zero. Receive a parcel and the first row lands '
                  'here, with what it cost and who booked it.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: context.dh.outlineVariant),
                  LedgerRow(
                    txn: rows[i],
                    uom: detail.item.uom,
                    jobCode: rows[i].jobId == null ? null : detail.jobCode(rows[i].jobId),
                    actorName: detail.personName(rows[i].createdBy),
                    supplierName: detail.supplierName(rows[i].supplierId),
                  ),
                ],
              ],
            ),
    );
  }
}

// ================================================================= actions

final class _Actions extends ConsumerWidget {
  const _Actions({required this.detail});

  final ItemDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(permissionsProvider);
    final busy = ref.watch(inventoryActionsProvider) != null;
    final item = detail.item;
    final blocked = permissions.blockReason(Capability.moveStock);
    final canAssign = blocked == null && item.qtyAvailable > 0;

    return VaultFooter(
      blockedReason: blocked,
      note: item.needsReorder
          ? 'This item is at or below its reorder level.'
          : null,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: blocked != null || busy
                    ? null
                    : () => unawaited(showStockTxnSheet(context, item: item)),
                icon: const Icon(Icons.swap_vert_rounded),
                label: const Text('Move stock'),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canAssign && !busy
                    ? () => unawaited(showAllocateSheet(context, item: item))
                    : null,
                icon: const Icon(Icons.bookmark_add_outlined),
                label: Text(canAssign ? 'Assign' : 'Nothing free'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
