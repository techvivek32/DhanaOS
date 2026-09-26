/// The vault's own components: the stock bar that was a hardcoded width, the species-typed stock
/// row, the ledger line and the reservation line.
///
/// `inventory_management` is the screen that shipped with no behaviour whatsoever — no search, no
/// filter, no assign, and **both stock bars drawn at a fixed percentage with no field behind
/// them**. [StockBar] is that bar with a real balance and a real threshold, and it renders
/// *nothing* when no reorder level has been set, because a bar with an invented denominator is
/// worse than no bar.
///
/// The other thing the mockup got right by accident and this makes deliberate: its diamond row
/// showed CARAT / COLOR / CLARITY while its ruby row showed CARAT / CUT / ORIGIN. Two rows, two
/// attribute sets — which is proof that a fixed 4C table is the wrong model for a gem vault.
/// [SpeciesAttributes] reads `InventoryItem.attrs` per species instead.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

// ================================================================= notes

/// What a strip of prose is doing on a vault screen.
enum VaultNoteTone {
  /// Context the keeper did not ask for but needs.
  info,

  /// What pressing the button will do. Gold, the house milestone colour.
  consequence,

  /// Something that will bite later — a shortfall, an undocumented custody record.
  risk,

  /// A rule that has been satisfied.
  good,
}

/// A bordered line of prose, so no vault screen invents its own warning treatment.
final class VaultNote extends StatelessWidget {
  const VaultNote({
    super.key,
    required this.text,
    this.tone = VaultNoteTone.info,
    this.icon,
    this.action,
  });

  final String text;
  final VaultNoteTone tone;
  final IconData? icon;

  /// One affordance on the right — "Count it", "Record it".
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    final (Color background, Color foreground, IconData glyph) = switch (tone) {
      VaultNoteTone.info => (
          dh.surfaceContainerLow,
          scheme.onSurfaceVariant,
          Icons.info_outline_rounded,
        ),
      VaultNoteTone.consequence => (
          dh.gold.withValues(alpha: 0.14),
          dh.goldText,
          Icons.bolt_outlined,
        ),
      VaultNoteTone.risk => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          Icons.warning_amber_rounded,
        ),
      VaultNoteTone.good => (
          dh.successContainer,
          dh.success,
          Icons.check_circle_outline_rounded,
        ),
    };

    return Container(
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      decoration: BoxDecoration(
        color: background,
        borderRadius: Radii.rMd,
        border: Border.all(color: dh.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? glyph, size: 16, color: foreground),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(text, style: context.text.bodySmall?.copyWith(color: foreground)),
          ),
          if (action != null) ...[
            const SizedBox(width: Spacing.sm),
            action!,
          ],
        ],
      ),
    );
  }
}

/// The pinned action bar for the vault's sheets and screens. A control that is shut always says
/// why, directly above itself.
final class VaultFooter extends StatelessWidget {
  const VaultFooter({
    super.key,
    required this.children,
    this.blockedReason,
    this.note,
    this.progress,
  });

  final List<Widget> children;

  /// Why the primary action is unavailable, in the operator's language.
  final String? blockedReason;

  /// Small print under the buttons: what pressing one will do.
  final String? note;

  /// Set while a file is in flight.
  final String? progress;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: dh.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (progress != null) ...[
                Row(
                  children: [
                    const VaultSpinner(size: 14),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        progress!,
                        style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.sm + Spacing.xs),
              ],
              if (blockedReason != null) ...[
                VaultNote(text: blockedReason!, tone: VaultNoteTone.risk),
                const SizedBox(height: Spacing.sm + Spacing.xs),
              ],
              ...children,
              if (note != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  note!,
                  textAlign: TextAlign.center,
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The in-button spinner, sized to sit inside a `FilledButton.icon` without resizing it.
final class VaultSpinner extends StatelessWidget {
  const VaultSpinner({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        // No colour: inside a button it inherits the button's foreground, which is the only way
        // one spinner can sit in a filled, a tonal and an outlined button without being wrong in
        // two of the three.
        child: const CircularProgressIndicator(strokeWidth: 2),
      );
}

// ================================================================= stock bar

/// The balance bar the mockup drew at a hardcoded width.
///
/// It measures on hand against the reorder level, which is the only threshold the schema stores —
/// so a full bar means "comfortably above the reorder point", not "the tray is full". When no
/// level has been set there is nothing to measure against and the bar is replaced by a single
/// honest line of text.
final class StockBar extends StatelessWidget {
  const StockBar({super.key, required this.item, this.dense = false});

  final InventoryItem item;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final ratio = item.stockRatio;
    final level = item.reorderLevel;

    if (ratio == null || level == null) {
      return Text(
        'No reorder level set — nothing to measure this balance against.',
        style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }

    // Three bands, and the colours carry the same meaning as everywhere else in the app: the
    // house gold means "a human has to act", error means "you are already short".
    final Color fill;
    if (item.needsReorder) {
      fill = scheme.error;
    } else if (ratio < 1.5) {
      fill = dh.gold;
    } else {
      fill = dh.success;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: Radii.rFull,
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: dense ? 6 : 8,
            backgroundColor: dh.surfaceContainerHigh,
            valueColor: AlwaysStoppedAnimation<Color>(fill),
          ),
        ),
        SizedBox(height: dense ? Spacing.xs : Spacing.sm),
        Row(
          children: [
            Text(
              item.quantityLabel,
              style: AppTheme.mono(
                size: dense ? 11 : 12.5,
                weight: FontWeight.w600,
                color: item.needsReorder ? scheme.error : scheme.onSurface,
              ),
            ),
            const Spacer(),
            Text(
              'reorder at ${trimDecimal(level, maxDigits: 3)} ${item.uom.symbol}',
              style: AppTheme.mono(size: dense ? 10 : 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

// ================================================================= species attributes

/// A gem's attributes, read per species out of `attrs`.
///
/// The mockup's own two rows are the argument for this: its diamond showed CARAT / COLOR /
/// CLARITY and its ruby showed CARAT / CUT / ORIGIN. A fixed four-column 4C table would print an
/// empty "Clarity" cell on every ruby and hide the treatment that actually sets its price.
///
/// Origin is always rendered, present or not (D-012). It survived in exactly one of 46 mockups,
/// and a missing origin is a fact the keeper has to see, not a cell to omit.
final class SpeciesAttributes extends StatelessWidget {
  const SpeciesAttributes({super.key, required this.item, this.columns = 3});

  final InventoryItem item;
  final int columns;

  /// The keys shown in addition to the typed columns, in the order a grader reads them.
  static const _gradedKeys = <String, String>{
    'color': 'Colour',
    'clarity': 'Clarity',
    'cut': 'Cut',
    'fluorescence': 'Fluorescence',
    'polish': 'Polish',
    'symmetry': 'Symmetry',
  };

  static const _colouredKeys = <String, String>{
    'cut': 'Cut',
    'treatment': 'Treatment',
    'provenance': 'Provenance',
    'tone': 'Tone',
    'saturation': 'Saturation',
  };

  @override
  Widget build(BuildContext context) {
    if (item.isBulkMetal) return _metal(context);

    final graded = item.stoneType?.usesFourCs ?? false;
    final keys = graded ? _gradedKeys : _colouredKeys;

    return DataPairGrid(
      columns: columns,
      children: [
        DataPair.mono(
          label: 'Species',
          value: item.stoneType?.label ?? DataPair.placeholder,
        ),
        // Never a blank cell: valuation, disclosure and certification all hang on this.
        DataPair.custom(
          label: 'Origin',
          tooltip: 'Natural and lab grown are different goods at different prices. The field '
              'survived in one of 46 source screens, so it is always on this card.',
          child: item.stoneOrigin == null
              ? const StatusChip(
                  label: 'Not stated',
                  tone: ChipTone.danger,
                  icon: Icons.help_outline_rounded,
                  dense: true,
                )
              : StatusChip.origin(item.stoneOrigin!, dense: true),
        ),
        DataPair.mono(label: 'Carat', value: caratLabel(item.carat)),
        DataPair.mono(label: 'Shape', value: item.shape?.label ?? DataPair.placeholder),
        for (final entry in keys.entries)
          if (item.attr(entry.key) != null)
            DataPair.mono(label: entry.value, value: item.attr(entry.key)!),
        // Anything the grader typed that this screen does not know a label for. A dropped
        // attribute is how 'origin' disappeared in the first place.
        for (final key in item.attrs.keys)
          if (!keys.containsKey(key) && item.attr(key) != null)
            DataPair.mono(label: _humanise(key), value: item.attr(key)!),
      ],
    );
  }

  Widget _metal(BuildContext context) => DataPairGrid(
        columns: columns,
        children: [
          DataPair.mono(
            label: 'Alloy',
            value: item.baseMetal?.label ?? DataPair.placeholder,
          ),
          DataPair.mono(label: 'Purity', value: item.purity?.label ?? DataPair.placeholder),
          DataPair.mono(label: 'Measured in', value: item.uom.symbol),
          for (final key in item.attrs.keys)
            if (item.attr(key) != null)
              DataPair.mono(label: _humanise(key), value: item.attr(key)!),
        ],
      );

  /// 'girdle_thickness' -> 'GIRDLE THICKNESS'. `DataPair` uppercases, so this only has to
  /// unsnake.
  static String _humanise(String key) => key.replaceAll('_', ' ');
}

// ================================================================= stock row

/// One line of stock, dense enough to scan a column of them and complete enough to act on.
///
/// The two stock models read differently on purpose. Metal shows a balance against its threshold,
/// because that is the number that decides whether to buy. A serialised stone shows its grade
/// summary and whether it is free, because there is no such thing as half of it.
final class StockRowCard extends StatelessWidget {
  const StockRowCard({
    super.key,
    required this.item,
    this.onTap,
    this.onAssign,
    this.trailing,
  });

  final InventoryItem item;
  final VoidCallback? onTap;

  /// The job picker the mockup's "Assign" button implied. Null when the operator cannot move
  /// stock, in which case the row is still readable — a keeper without the role can look.
  final VoidCallback? onAssign;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final cost = item.unitCost;

    return DhCard(
      onTap: onTap,
      accent: item.needsReorder ? scheme.error : null,
      semanticLabel: '${item.code}, ${item.label}, ${item.availableLabel} available'
          '${item.needsReorder ? ', below reorder level' : ''}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusChip.code(item.code, dense: true),
              const SizedBox(width: Spacing.sm),
              if (item.isSerialized && item.stoneOrigin != null)
                StatusChip.origin(item.stoneOrigin!, dense: true)
              else if (item.isSerialized)
                const StatusChip(
                  label: 'Origin not stated',
                  tone: ChipTone.danger,
                  dense: true,
                  icon: Icons.help_outline_rounded,
                ),
              const Spacer(),
              if (trailing != null)
                trailing!
              else if (item.needsReorder)
                const StatusChip(
                  label: 'Reorder',
                  tone: ChipTone.danger,
                  icon: Icons.trending_down_rounded,
                  dense: true,
                )
              else if (item.isSerialized && !item.isInStock)
                const StatusChip(label: 'Committed', tone: ChipTone.warning, dense: true),
            ],
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.titleMedium,
          ),
          const SizedBox(height: 2),
          Text(
            // Species-typed: '1.25 ct · Oval · Natural · Unheated' for a ruby,
            // '… · F · VVS2' for a diamond, '18K Gold' for a parcel of metal.
            item.gradeSummary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.mono(size: 11.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          if (item.isBulkMetal)
            StockBar(item: item, dense: true)
          else
            Row(
              children: [
                Icon(
                  item.isInStock ? Icons.check_circle_outline_rounded : Icons.lock_outline_rounded,
                  size: 15,
                  color: item.isInStock ? context.dh.success : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Spacing.xs),
                Text(
                  item.isInStock ? 'In the vault' : 'Committed to a job',
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              if (item.location != null) ...[
                Icon(Icons.place_outlined, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: Spacing.xs),
                Flexible(
                  child: Text(
                    item.location!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
              ],
              if (item.isBulkMetal)
                Text(
                  'free ${item.availableLabel}',
                  style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
                ),
              const Spacer(),
              if (cost != null)
                Text(
                  // Per unit for a parcel, absolute for a stone that is its own unit.
                  item.isSerialized
                      ? cost.format(compact: true)
                      : '${cost.format(compact: true)}/${item.uom.symbol}',
                  style: AppTheme.mono(
                    size: 12,
                    weight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              if (onAssign != null) ...[
                const SizedBox(width: Spacing.sm),
                TextButton(
                  onPressed: onAssign,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                  ),
                  child: const Text('Assign'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ================================================================= ledger

/// One movement. Signed, because direction is the whole point of a ledger line.
final class LedgerRow extends StatelessWidget {
  const LedgerRow({
    super.key,
    required this.txn,
    required this.uom,
    this.jobCode,
    this.actorName,
    this.supplierName,
  });

  final StockTransaction txn;
  final Uom uom;
  final String? jobCode;
  final String? actorName;
  final String? supplierName;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final value = txn.value;

    final (Color colour, IconData glyph) = switch (txn.kind) {
      StockTxnKind.receive => (dh.success, Icons.south_west_rounded),
      StockTxnKind.returned => (dh.success, Icons.undo_rounded),
      StockTxnKind.issue => (scheme.onSurface, Icons.north_east_rounded),
      // Scrap is metal that will never come back. It reads as a loss, because it is one.
      StockTxnKind.scrap => (scheme.error, Icons.delete_sweep_outlined),
      StockTxnKind.adjust => (
          txn.qty < 0 ? scheme.error : dh.goldText,
          Icons.balance_rounded,
        ),
      StockTxnKind.allocate => (scheme.onSurfaceVariant, Icons.bookmark_border_rounded),
      StockTxnKind.release => (scheme.onSurfaceVariant, Icons.bookmark_remove_outlined),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm + Spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: dh.surfaceContainerHigh,
              borderRadius: Radii.rSm,
            ),
            child: Center(child: Icon(glyph, size: 16, color: colour)),
          ),
          const SizedBox(width: Spacing.sm + Spacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(txn.kind.label, style: context.text.titleMedium),
                    const SizedBox(width: Spacing.sm),
                    if (jobCode != null) StatusChip.code(jobCode!, dense: true),
                    const Spacer(),
                    Text(
                      txn.qtyLabel(uom),
                      style: AppTheme.mono(size: 13.5, weight: FontWeight.w600, color: colour),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  _subtitle(),
                  style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
                ),
                if (txn.note != null) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    txn.note!,
                    style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
                if (value != null) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    'at ${value.format()}',
                    style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Convention 7: Postgres hands us UTC, the operator reads local time.
  String _subtitle() {
    final parts = <String>[
      DateFormat('d MMM yyyy · HH:mm').format(txn.createdAt.toLocal()),
      if (actorName != null) actorName!,
      if (supplierName != null) supplierName!,
      if (txn.reference != null) txn.reference!,
      if (txn.lotRef != null) 'lot ${txn.lotRef}',
      if (txn.stage != null) txn.stage!.label,
    ];
    return parts.join('  ·  ');
  }
}

// ================================================================= reservation

/// One reservation against the item, with the two acts it still admits.
final class AllocationRow extends StatelessWidget {
  const AllocationRow({
    super.key,
    required this.allocation,
    required this.uom,
    this.jobCode,
    this.actorName,
    this.onIssue,
    this.onRelease,
    this.busy = false,
  });

  final StockAllocation allocation;
  final Uom uom;
  final String? jobCode;
  final String? actorName;

  /// Pull it from the vault: this posts the movement that takes it off the balance.
  final VoidCallback? onIssue;

  /// Give it back. Nothing left the vault, so nothing is posted.
  final VoidCallback? onRelease;

  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;

    final (String state, ChipTone tone) = switch (allocation) {
      StockAllocation(isOpen: false) => ('Released', ChipTone.neutral),
      StockAllocation(isIssued: true) => ('Issued', ChipTone.accent),
      _ => ('Reserved', ChipTone.warning),
    };

    return DhCard(
      tone: DhCardTone.inset,
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (jobCode != null) StatusChip.code(jobCode!, dense: true),
              const SizedBox(width: Spacing.sm),
              StatusChip(label: state, tone: tone, dense: true),
              const Spacer(),
              Text(
                '${trimDecimal(allocation.qty, maxDigits: 3)} ${uom.symbol}',
                style: AppTheme.mono(
                  size: 13,
                  weight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs + 2),
          Text(
            [
              DateFormat('d MMM yyyy · HH:mm').format(allocation.allocatedAt.toLocal()),
              if (actorName != null) actorName!,
              if (allocation.stoneId != null) 'stone line',
            ].join('  ·  '),
            style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
          ),
          if (onIssue != null || onRelease != null) ...[
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                if (onIssue != null)
                  FilledButton.tonalIcon(
                    onPressed: busy ? null : onIssue,
                    icon: busy
                        ? const VaultSpinner(size: 14)
                        : const Icon(Icons.output_rounded, size: 16),
                    label: const Text('Issue from vault'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(Spacing.rowHeight),
                    ),
                  ),
                if (onIssue != null && onRelease != null) const SizedBox(width: Spacing.sm),
                if (onRelease != null)
                  OutlinedButton(
                    onPressed: busy ? null : onRelease,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(Spacing.rowHeight),
                    ),
                    child: const Text('Release'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= toggles

/// A switch with the consequence of turning it on written beside it.
///
/// The vault's toggles all change what a button will *do* — issue as well as reserve, acknowledge
/// a risk on the client's behalf — so none of them is a bare switch with a noun next to it.
final class ToggleTile extends StatelessWidget {
  const ToggleTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.blurb,
    this.enabled = true,
    this.tone = VaultNoteTone.info,
  });

  final String title;

  /// What happens because it is on. Never "enable this option".
  final String? blurb;

  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  /// `consequence` for an act with a cost, `risk` for the custody acknowledgement.
  final VaultNoteTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final accent = switch (tone) {
      VaultNoteTone.consequence => dh.goldText,
      VaultNoteTone.risk => scheme.error,
      VaultNoteTone.good => dh.success,
      VaultNoteTone.info => scheme.secondary,
    };

    return DhCard(
      tone: DhCardTone.inset,
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.sm, Spacing.sm, Spacing.sm),
      // DhCard's selected ring is the house treatment for "this is on"; the tone shows up on the
      // thumb, where it cannot be confused with a selection.
      selected: value,
      onTap: enabled ? () => onChanged(!value) : null,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: context.text.titleMedium?.copyWith(
                    color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
                  ),
                ),
                if (blurb != null) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    blurb!,
                    style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Switch(
            value: value,
            onChanged: enabled ? onChanged : null,
            activeThumbColor: accent,
          ),
        ],
      ),
    );
  }
}

// ================================================================= headings

/// The uppercase mono section heading the source screens repeated above every block.
final class VaultHeading extends StatelessWidget {
  const VaultHeading(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      );
}

// ================================================================= file capture

/// Where a vault file comes from.
///
/// A voice note is deliberately absent, as it is in QC: a condition photograph and a certificate
/// scan are things a later reader — or an insurer — has to be able to *look* at.
enum VaultFileSource {
  camera('Take a photo', Icons.photo_camera_outlined, 'The stone at the counter, under the loupe'),
  gallery('Choose a photo', Icons.photo_library_outlined, 'Something already on this device'),
  file('Attach a file', Icons.attach_file_rounded, 'A certificate scan, a lab report, a PDF');

  const VaultFileSource(this.label, this.icon, this.blurb);

  final String label;
  final IconData icon;
  final String blurb;
}

/// A file chosen on the device, before it has an attachment id.
final class PickedVaultFile {
  const PickedVaultFile(this.file, this.filename);

  final File file;

  /// The name the operator will recognise in the file list.
  final String filename;
}

/// Ask where the file is coming from. Null when the operator backed out.
Future<VaultFileSource?> pickVaultFileSource(
  BuildContext context, {
  required String title,
  required String blurb,
  bool allowFiles = true,
}) {
  final sources = allowFiles
      ? VaultFileSource.values
      : [VaultFileSource.camera, VaultFileSource.gallery];

  return showModalBottomSheet<VaultFileSource>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: sheetContext.text.headlineSmall
                  ?.copyWith(color: sheetContext.scheme.onSurface),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              blurb,
              style: sheetContext.text.bodySmall
                  ?.copyWith(color: sheetContext.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.md),
            for (final source in sources) ...[
              SelectableTile(
                title: source.label,
                blurb: source.blurb,
                icon: source.icon,
                onTap: () => Navigator.of(sheetContext).pop(source),
              ),
              const SizedBox(height: Spacing.sm),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Run the chosen picker. Null when the operator cancelled inside it.
///
/// Throws a [StorageFailure] when the picker itself could not open — a denied camera permission
/// is the common one, and "nothing happened" is not something an operator can act on. Takes no
/// [BuildContext] on purpose, so no caller has to reason about a context that crossed an await.
Future<PickedVaultFile?> takeVaultFile(VaultFileSource source) => switch (source) {
      VaultFileSource.camera => _pickPhoto(ImageSource.camera),
      VaultFileSource.gallery => _pickPhoto(ImageSource.gallery),
      VaultFileSource.file => _pickFile(),
    };

Future<PickedVaultFile?> _pickPhoto(ImageSource source) async {
  try {
    // 88 keeps a 12MP counter photo under a megabyte, which matters on a 4G upload and loses
    // nothing an insurer will ever look at.
    final shot = await ImagePicker().pickImage(source: source, imageQuality: 88);
    return shot == null ? null : PickedVaultFile(File(shot.path), shot.name);
  } on Exception catch (error, stack) {
    Error.throwWithStackTrace(
      StorageFailure(
        message: source == ImageSource.camera
            ? 'The camera could not be opened. Check that DhanaOS has camera permission in '
                'Android settings, then try again.'
            : 'The photo library could not be opened. Check that DhanaOS has photo permission '
                'in Android settings.',
        detail: '$error',
        code: 'picker_unavailable',
      ),
      stack,
    );
  }
}

/// One file off the device.
///
/// Two things about file_picker 13 that the call has to respect: `FilePicker.pickFile` is a static
/// method now (`FilePicker.platform` no longer exists), and on Android a Storage Access Framework
/// pick comes back as a `content://` URI whose [PlatformFile.path] is **null**. Treating a null
/// path as "cancelled" would make the picker silently do nothing on exactly the files a keeper is
/// most likely to choose, so the bytes are spooled into the cache directory and the upload streams
/// from there.
Future<PickedVaultFile?> _pickFile() async {
  try {
    final picked = await FilePicker.pickFile();
    if (picked == null) return null;

    final onDisk = picked.path;
    final name = picked.name.replaceAll(RegExp(r'[\\/]'), '_');
    if (onDisk != null) return PickedVaultFile(File(onDisk), name);

    final bytes = await picked.readAsBytes();
    final dir = await getTemporaryDirectory();
    final copy = File('${dir.path}/${DateTime.now().microsecondsSinceEpoch}-$name');
    await copy.writeAsBytes(bytes, flush: true);
    return PickedVaultFile(copy, name);
  } on Exception catch (error, stack) {
    Error.throwWithStackTrace(
      StorageFailure(
        message: 'The file browser could not be opened. Photograph the document instead.',
        detail: '$error',
        code: 'file_picker_unavailable',
      ),
      stack,
    );
  }
}

// ================================================================= formatting

/// A quantity in the item's own unit: '124.5 g', '1 pc'. Three decimals because that is what
/// `numeric(12,3)` holds and a gem scale resolves.
String qtyLabel(double qty, Uom uom) => '${trimDecimal(qty, maxDigits: 3)} ${uom.symbol}';

/// '+124.5 g' / '−0.8 g'. Signed, for a figure whose direction is its meaning.
String signedQtyLabel(double qty, Uom uom) {
  final sign = qty > 0 ? '+' : (qty < 0 ? '−' : '');
  return '$sign${trimDecimal(qty.abs(), maxDigits: 3)} ${uom.symbol}';
}

/// The step a stepper should take for a unit: a gem scale reads hundredths of a carat, a bench
/// scale tenths of a gram, and a stone is one stone.
double stepFor(Uom uom) => switch (uom) {
      Uom.gram => 0.1,
      Uom.carat => 0.01,
      Uom.piece => 1,
    };

int decimalsFor(Uom uom) => switch (uom) {
      Uom.gram || Uom.carat => 2,
      Uom.piece => 0,
    };

/// '2 days ago' — how long the shop has been holding something. Custody duration is the figure
/// an insurer asks about first.
String custodySpan(Duration d) {
  if (d.inDays >= 1) return '${d.inDays}d in custody';
  if (d.inHours >= 1) return '${d.inHours}h in custody';
  return '${d.inMinutes}m in custody';
}

/// A money figure that may not exist yet. Never renders "0" for "not priced" — an unpriced
/// parcel and a free one are different facts.
String moneyOrDash(Money? amount, {bool compact = false}) =>
    amount == null ? DataPair.placeholder : amount.format(compact: compact);
