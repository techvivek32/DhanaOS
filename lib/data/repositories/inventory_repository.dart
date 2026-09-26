/// Typed data access for the vault: stock, allocations, the movement ledger and goods-in
/// custody.
///
/// `inventory_management` shipped no JavaScript at all — search, filter and "Assign" did
/// nothing, and both stock bars were hardcoded widths. Two distinct stock models coexisted in
/// that one screen and both are honoured here: metal is a bulk balance in grams, a stone is a
/// serialised item where the row *is* the stone.
///
/// Three rules shape this file:
///
///  * **Balances are never written.** `qty_on_hand` is maintained by `trg_stock_balance` from
///    `stock_transactions`, which is append-only (UPDATE and DELETE are revoked in Postgres).
///    So stock moves by [InventoryRepository.post], never by an update to the item. Jewellery
///    manufacturing loses measurable metal to filings, polishing and sprues; a ledger is the
///    only thing that can reconcile that at month end, and the mockup's own dashboard raised
///    "Melee diamonds count mismatch at receiving" while offering nothing that could record a
///    movement.
///  * **`qty_allocated` is derived, then rewritten.** No trigger owns it, and `inv_alloc_sane`
///    constrains it, so [_syncAllocatedQty] recomputes it from the open reservations after every
///    change rather than incrementing it. A lost `+=` drifts permanently; a lost recomputation
///    is corrected by the next one.
///  * **A serialised stone always states its origin.** D-012: `stone_origin` survived in exactly
///    one mockup out of 46 and every later redesign dropped it. Natural and lab-grown are
///    different goods at different prices, so [createItem] refuses a stone without one.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'inventory_repository.g.dart';

/// Floating-point slack for a quantity comparison. `numeric(12,3)` holds three decimals, so
/// anything under half a milligram is rounding noise rather than a real shortfall — without this
/// a 1.000 g allocation against a 1.000 g balance can fail on a binary representation.
const _qtyEpsilon = 0.0005;

final class InventoryRepository {
  const InventoryRepository(this._client, this._identity);

  final SupabaseClient _client;

  /// D-008: `org_id` and the actor come from the signed-in operator's `app_users` row and from
  /// nowhere else. A repository never invents either.
  final RepoIdentity _identity;

  String get _org => _identity.requireOrgId();

  /// The named person on a movement and, crucially, on a custody receipt. A goods-in record whose
  /// verifier is nobody is exactly the gap this layer exists to close.
  String get _actor => _identity.requireUserId();

  // -------------------------------------------------------------- browse

  /// The vault, from `v_inventory_available` — the view that computes `qty_available` and
  /// `needs_reorder` in SQL so those can be filtered server-side instead of over a list that was
  /// already truncated by [limit].
  ///
  /// [origin] is a first-class filter, not a nicety: a job specified as lab-grown must never be
  /// satisfied from a natural parcel (D-012).
  Future<List<InventoryItem>> availableStock({
    StockKind? kind,
    String? search,
    BaseMetal? baseMetal,
    MetalPurity? purity,
    StoneType? stoneType,
    StoneOrigin? origin,
    StoneShape? shape,
    bool inStockOnly = false,
    bool needsReorderOnly = false,
    int limit = 100,
  }) async {
    final rows = await guard(() {
      var query = _client.from('v_inventory_available').select().eq('org_id', _org);
      // Convention 6: every enum crosses the wire as its Postgres value.
      if (kind != null) query = query.eq('kind', kind.wire);
      if (baseMetal != null) query = query.eq('base_metal', baseMetal.wire);
      if (purity != null) query = query.eq('purity', purity.wire);
      if (stoneType != null) query = query.eq('stone_type', stoneType.wire);
      if (origin != null) query = query.eq('stone_origin', origin.wire);
      if (shape != null) query = query.eq('shape', shape.wire);
      if (inStockOnly) query = query.gt('qty_available', 0);
      if (needsReorderOnly) query = query.eq('needs_reorder', true);

      final term = search == null ? '' : _searchTerm(search);
      if (term.isNotEmpty) {
        query = query.or('code.ilike.%$term%,label.ilike.%$term%');
      }
      return query.order('code', ascending: true).limit(limit);
    });
    return [for (final row in rows) InventoryItem.fromJson(row)];
  }

  /// One item, including a deactivated one — read from the table rather than the view, because
  /// `v_inventory_available` filters `is_active` and a ledger still has to be able to name the
  /// item a historic movement was against.
  Future<InventoryItem?> itemById(String itemId) async {
    final row = await guard(
      () => _client.from('inventory_items').select().eq('id', itemId).maybeSingle(),
    );
    return row == null ? null : InventoryItem.fromJson(row);
  }

  /// 'AU-750', 'DIA-9982-A' — the code an operator reads off the tray label.
  Future<InventoryItem?> itemByCode(String code) async {
    final row = await guard(
      () => _client
          .from('inventory_items')
          .select()
          .eq('org_id', _org)
          .eq('code', code.trim())
          .maybeSingle(),
    );
    return row == null ? null : InventoryItem.fromJson(row);
  }

  // -------------------------------------------------------------- items

  /// Create a stock item.
  ///
  /// It starts at zero on hand. Putting stock on the shelf is a [receive] movement, because the
  /// balance belongs to the ledger — creating an item with an opening quantity would be the one
  /// balance in the system with no row explaining where it came from.
  ///
  /// [attrs] carries the species-typed grades: `{"color":"F","clarity":"VVS2"}` for a diamond,
  /// `{"cut":"EX","treatment":"Unheated"}` for a ruby. The mockup's diamond row showed
  /// CARAT/COLOR/CLARITY while its ruby row showed CARAT/CUT/ORIGIN, so a fixed 4C table would
  /// be wrong.
  Future<InventoryItem> createItem({
    required StockKind kind,
    required String code,
    required String label,
    Uom? uom,
    double? reorderLevel,
    BaseMetal? baseMetal,
    MetalPurity? purity,
    StoneType? stoneType,
    StoneOrigin? stoneOrigin,
    StoneShape? shape,
    double? carat,
    Map<String, dynamic> attrs = const <String, dynamic>{},
    CertLab? certLab,
    String? certNumber,
    String? certPdfId,
    Money? unitCost,
    String? supplierId,
    String? lotRef,
    String? location,
    String? photoId,
  }) async {
    final sku = code.trim();
    final name = label.trim();
    if (sku.isEmpty || name.isEmpty) {
      throw const RuleViolation(
        message: 'A stock item needs both a code and a description. The code is what is on the '
            'tray; the description is what the bench recognises.',
        code: 'item_unlabelled',
      );
    }

    // D-012, the field every redesign dropped. Natural versus lab-grown changes valuation,
    // disclosure obligations and certification, so a serialised stone cannot be entered without
    // it.
    if (kind == StockKind.stoneSerialized && stoneOrigin == null) {
      throw const RuleViolation(
        message: 'Set the stone origin — Natural or Lab Grown. It changes what the stone is '
            'worth, what has to be disclosed and how it is certified.',
        code: 'stone_origin_missing',
      );
    }
    // D-012's other dependency: 22K rose gold is not a product.
    if (baseMetal != null && purity != null && !baseMetal.purities.contains(purity)) {
      throw RuleViolation(
        message: '${purity.label} is not a purity ${baseMetal.label.toLowerCase()} comes in. '
            'Pick one of: ${baseMetal.purities.map((p) => p.label).join(', ')}.',
        code: 'purity_mismatch',
      );
    }

    final row = await guard(
      () => _client
          .from('inventory_items')
          .insert(<String, dynamic>{
            'org_id': _org,
            'kind': kind.wire,
            'code': sku,
            'label': name,
            'uom': (uom ?? _defaultUom(kind)).wire,
            'reorder_level': reorderLevel,
            'base_metal': baseMetal?.wire,
            'purity': purity?.wire,
            'stone_type': stoneType?.wire,
            'stone_origin': stoneOrigin?.wire,
            'shape': shape?.wire,
            'carat': carat,
            'attrs': attrs,
            'cert_lab': certLab?.wire,
            'cert_number': certNumber?.trim(),
            'cert_pdf_id': certPdfId,
            'unit_cost': unitCost?.minor,
            if (unitCost != null) 'currency': unitCost.currency,
            'supplier_id': supplierId,
            'lot_ref': lotRef?.trim(),
            'location': location?.trim(),
            'photo_id': photoId,
          })
          .select()
          .single(),
    );
    return InventoryItem.fromJson(row);
  }

  /// Edit the descriptive side of an item. Quantities are absent on purpose — they move through
  /// [post].
  Future<InventoryItem> updateItem({
    required String itemId,
    String? label,
    double? reorderLevel,
    StoneOrigin? stoneOrigin,
    Map<String, dynamic>? attrs,
    CertLab? certLab,
    String? certNumber,
    String? certPdfId,
    Money? unitCost,
    String? supplierId,
    String? lotRef,
    String? location,
    String? photoId,
    bool? isActive,
  }) async {
    final values = <String, dynamic>{
      if (label != null) 'label': label.trim(),
      if (reorderLevel != null) 'reorder_level': reorderLevel,
      if (stoneOrigin != null) 'stone_origin': stoneOrigin.wire,
      if (attrs != null) 'attrs': attrs,
      if (certLab != null) 'cert_lab': certLab.wire,
      if (certNumber != null) 'cert_number': _blankToNull(certNumber),
      if (certPdfId != null) 'cert_pdf_id': certPdfId,
      if (unitCost != null) 'unit_cost': unitCost.minor,
      if (unitCost != null) 'currency': unitCost.currency,
      if (supplierId != null) 'supplier_id': supplierId,
      if (lotRef != null) 'lot_ref': _blankToNull(lotRef),
      if (location != null) 'location': _blankToNull(location),
      if (photoId != null) 'photo_id': photoId,
      if (isActive != null) 'is_active': isActive,
    };
    if (values.isEmpty) {
      final current = await itemById(itemId);
      if (current == null) throw _itemGone(itemId);
      return current;
    }

    final row = await guard(
      () => _client
          .from('inventory_items')
          .update(values)
          .eq('id', itemId)
          .select()
          .single(),
    );
    return InventoryItem.fromJson(row);
  }

  // -------------------------------------------------------------- allocations

  /// What is committed to a job. `alloc_job_idx` is partial on `released_at is null`, so the open
  /// query is the cheap one — and it is the one a job screen asks.
  Future<List<StockAllocation>> allocationsForJob(
    String jobId, {
    bool openOnly = true,
  }) async {
    final rows = await guard(() {
      final query = _client.from('stock_allocations').select().eq('job_id', jobId);
      final scoped = openOnly ? query.isFilter('released_at', null) : query;
      return scoped.order('allocated_at', ascending: false);
    });
    return [for (final row in rows) StockAllocation.fromJson(row)];
  }

  /// Which jobs are holding this item — what an inventory keeper needs before telling a bench
  /// "there is none left".
  Future<List<StockAllocation>> allocationsForItem(
    String itemId, {
    bool openOnly = true,
  }) async {
    final rows = await guard(() {
      final query = _client.from('stock_allocations').select().eq('item_id', itemId);
      final scoped = openOnly ? query.isFilter('released_at', null) : query;
      return scoped.order('allocated_at', ascending: false);
    });
    return [for (final row in rows) StockAllocation.fromJson(row)];
  }

  /// Reserve stock against a job — the job picker the mockup's single "Assign" button implied
  /// and did not have.
  ///
  /// Reserved is not issued: the stone is still on the shelf, and `qty_on_hand` does not move
  /// until [issueAllocation] posts the movement.
  Future<StockAllocation> allocate({
    required String itemId,
    required String jobId,
    required double qty,
    String? stoneId,
  }) async {
    if (qty <= 0) {
      throw const RuleViolation(
        message: 'Enter a quantity above zero.',
        code: 'alloc_not_positive',
      );
    }

    final item = await itemById(itemId);
    if (item == null) throw _itemGone(itemId);

    // There is no partial diamond: a serialised item IS the stone.
    if (item.isSerialized && qty != 1) {
      throw RuleViolation(
        message: '${item.displayLabel} is a single serialised stone. Allocate it as one, or pick '
            'a parcel instead.',
        code: 'serialized_qty',
      );
    }
    if (item.qtyAvailable + _qtyEpsilon < qty) {
      throw RuleViolation(
        message: 'Only ${item.availableLabel} of ${item.displayLabel} is free. '
            '${item.quantityLabel} is on hand and the rest is already committed to other jobs.',
        detail: 'item=$itemId requested=$qty available=${item.qtyAvailable}',
        code: 'alloc_insufficient',
      );
    }

    final row = await guard(
      () => _client
          .from('stock_allocations')
          .insert(<String, dynamic>{
            'item_id': itemId,
            'job_id': jobId,
            'stone_id': stoneId,
            'qty': qty,
            'allocated_by': _actor,
          })
          .select()
          .single(),
    );
    await _syncAllocatedQty(itemId);
    return StockAllocation.fromJson(row);
  }

  /// Give the reservation back. The stock never left the vault, so no movement is posted.
  Future<StockAllocation> releaseAllocation(String allocationId) async {
    final row = await guard(
      () => _client
          .from('stock_allocations')
          .update(<String, dynamic>{'released_at': _now()})
          .eq('id', allocationId)
          .select()
          .single(),
    );
    final allocation = StockAllocation.fromJson(row);
    await _syncAllocatedQty(allocation.itemId);
    return allocation;
  }

  /// Physically pull it from the vault: mark the allocation issued and post the movement that
  /// takes it off the balance.
  ///
  /// The reservation is cleared *before* the movement, not after. `inv_alloc_sane` requires
  /// `qty_allocated <= qty_on_hand`, so posting first would break that check the moment a job
  /// consumes the last of an item — and the operator would get a constraint name instead of an
  /// answer. If the movement is then refused, the reservation is put back, because stock that
  /// never left must not read as issued.
  Future<StockAllocation> issueAllocation(
    String allocationId, {
    LifecycleStage? stage,
    String? note,
  }) async {
    final allocation = await _allocation(allocationId);
    if (allocation.isIssued) return allocation;
    if (!allocation.isOpen) {
      throw const RuleViolation(
        message: 'That reservation was already released. Allocate the stock again before issuing '
            'it.',
        code: 'alloc_released',
      );
    }

    await guard(
      () => _client
          .from('stock_allocations')
          .update(<String, dynamic>{'issued_at': _now()})
          .eq('id', allocationId),
    );
    await _syncAllocatedQty(allocation.itemId);

    try {
      await post(
        itemId: allocation.itemId,
        kind: StockTxnKind.issue,
        qty: allocation.qty,
        jobId: allocation.jobId,
        stage: stage,
        note: note,
      );
    } on DhFailure {
      await guard(
        () => _client
            .from('stock_allocations')
            .update(<String, dynamic>{'issued_at': null})
            .eq('id', allocationId),
      );
      await _syncAllocatedQty(allocation.itemId);
      rethrow;
    }

    return _allocation(allocationId);
  }

  Future<StockAllocation> _allocation(String allocationId) async {
    final row = await guard(
      () => _client.from('stock_allocations').select().eq('id', allocationId).single(),
    );
    return StockAllocation.fromJson(row);
  }

  /// Recompute `qty_allocated` from the reservations that are still holding stock — open and not
  /// yet pulled ([StockAllocation.isReservedOnly]).
  ///
  /// Derived-and-rewritten rather than incremented: two keepers allocating at once would lose one
  /// `+=` forever, while a lost recomputation is repaired by the next allocation on the item.
  /// Issued allocations are excluded because their quantity has already left `qty_on_hand`, and
  /// counting it twice would trip `inv_alloc_sane`.
  Future<void> _syncAllocatedQty(String itemId) async {
    final rows = await guard(
      () => _client
          .from('stock_allocations')
          .select('qty')
          .eq('item_id', itemId)
          .isFilter('released_at', null)
          .isFilter('issued_at', null),
    );
    var total = 0.0;
    for (final row in rows) {
      total += (row['qty'] as num).toDouble();
    }
    await guard(
      () => _client
          .from('inventory_items')
          .update(<String, dynamic>{'qty_allocated': total})
          .eq('id', itemId),
    );
  }

  // -------------------------------------------------------------- ledger

  /// The movement history. Append-only in Postgres, so this is the whole truth about a balance.
  Future<List<StockTransaction>> ledger({
    String? itemId,
    String? jobId,
    StockTxnKind? kind,
    int limit = 100,
  }) async {
    final rows = await guard(() {
      var query = _client.from('stock_transactions').select().eq('org_id', _org);
      if (itemId != null) query = query.eq('item_id', itemId);
      if (jobId != null) query = query.eq('job_id', jobId);
      if (kind != null) query = query.eq('kind', kind.wire);
      return query.order('created_at', ascending: false).limit(limit);
    });
    return [for (final row in rows) StockTransaction.fromJson(row)];
  }

  /// Post a movement. This is the only way a balance changes.
  ///
  /// Pass [qty] as a magnitude: the kind decides the direction, from [StockTxnKind.sign]. The one
  /// exception is `adjust`, which reports no sign because a stock-take can go either way, so
  /// there the operator's own sign is kept.
  ///
  /// `trg_stock_balance` refuses a movement that would take the item below zero. Its message
  /// names the item by uuid, which is no use at a bench, so it is re-read and restated with the
  /// item's code and the quantity actually on hand.
  Future<StockTransaction> post({
    required String itemId,
    required StockTxnKind kind,
    required double qty,
    String? jobId,
    LifecycleStage? stage,
    Money? unitCost,
    String? supplierId,
    String? lotRef,
    String? reference,
    String? note,
  }) async {
    final direction = kind.sign;
    final signed = direction == 0 ? qty : qty.abs() * direction;
    if (signed == 0) {
      throw const RuleViolation(
        message: 'Enter a quantity. A movement of zero records nothing.',
        code: 'txn_zero',
      );
    }

    try {
      final row = await guard(
        () => _client
            .from('stock_transactions')
            .insert(<String, dynamic>{
              'org_id': _org,
              'item_id': itemId,
              'kind': kind.wire,
              'qty': signed,
              'job_id': jobId,
              'stage': stage?.wire,
              'unit_cost': unitCost?.minor,
              if (unitCost != null) 'currency': unitCost.currency,
              'supplier_id': supplierId,
              'lot_ref': lotRef?.trim(),
              'reference': reference?.trim(),
              'note': note?.trim(),
              'created_by': _actor,
            })
            .select()
            .single(),
      );
      return StockTransaction.fromJson(row);
    } on RuleViolation catch (failure, stack) {
      if (!failure.message.contains('would go negative')) rethrow;
      final item = await itemById(itemId);
      Error.throwWithStackTrace(
        RuleViolation(
          message: item == null
              ? 'That movement would take the item below zero. Check the quantity.'
              : 'Only ${item.quantityLabel} of ${item.displayLabel} is on hand. This movement '
                  'would take it below zero — count the tray and post an adjustment first.',
          detail: failure.message,
          code: failure.code,
        ),
        stack,
      );
    }
  }

  /// Goods in from a supplier. [unitCost] is what makes an on-hand valuation possible at all —
  /// the mockup had no costing fields whatsoever.
  Future<StockTransaction> receive({
    required String itemId,
    required double qty,
    Money? unitCost,
    String? supplierId,
    String? lotRef,
    String? reference,
    String? note,
  }) =>
      post(
        itemId: itemId,
        kind: StockTxnKind.receive,
        qty: qty,
        unitCost: unitCost,
        supplierId: supplierId,
        lotRef: lotRef,
        reference: reference,
        note: note,
      );

  /// Straight to a job without a prior reservation — a bench pulling 0.4 g of solder.
  Future<StockTransaction> issueToJob({
    required String itemId,
    required String jobId,
    required double qty,
    LifecycleStage? stage,
    String? note,
  }) =>
      post(
        itemId: itemId,
        kind: StockTxnKind.issue,
        qty: qty,
        jobId: jobId,
        stage: stage,
        note: note,
      );

  /// Filings, polishing loss and casting sprues — the line that has to reconcile at month end.
  /// Pair it with the bench figure recorded in `ProductionRepository.recordMeasurement`, which
  /// captures the same loss against the job.
  Future<StockTransaction> scrap({
    required String itemId,
    required double qty,
    String? jobId,
    LifecycleStage? stage,
    String? note,
  }) =>
      post(
        itemId: itemId,
        kind: StockTxnKind.scrap,
        qty: qty,
        jobId: jobId,
        stage: stage,
        note: note,
      );

  /// Unused metal or a rejected stone coming back to the vault.
  Future<StockTransaction> returnToStock({
    required String itemId,
    required double qty,
    String? jobId,
    LifecycleStage? stage,
    String? note,
  }) =>
      post(
        itemId: itemId,
        kind: StockTxnKind.returned,
        qty: qty,
        jobId: jobId,
        stage: stage,
        note: note,
      );

  /// A stock-take correction. [delta] keeps its sign — negative for a shortfall, positive for a
  /// find — and a reason is required, because an unexplained adjustment is indistinguishable
  /// from a loss.
  Future<StockTransaction> adjust({
    required String itemId,
    required double delta,
    required String note,
    String? reference,
  }) async {
    final reason = note.trim();
    if (reason.isEmpty) {
      throw const RuleViolation(
        message: 'Say what the count found. An adjustment with no reason reads as a missing '
            'stone later.',
        code: 'adjust_no_reason',
      );
    }
    return post(
      itemId: itemId,
      kind: StockTxnKind.adjust,
      qty: delta,
      reference: reference,
      note: reason,
    );
  }

  // -------------------------------------------------------------- goods-in custody

  /// The custody record for a client's own materials.
  Future<List<GoodsInReceipt>> receipts(String jobId) async {
    final rows = await guard(
      () => _client
          .from('goods_in_receipts')
          .select()
          .eq('job_id', jobId)
          .order('received_at', ascending: false),
    );
    return [for (final row in rows) GoodsInReceipt.fromJson(row)];
  }

  /// 'GRN-2026-00184'. As with an invoice number the unique index is the arbiter; a collision
  /// surfaces as a [DuplicateRecord] and the operator takes the next suggestion.
  Future<String> suggestReceiptCode() async {
    final year = DateTime.now().year;
    final prefix = 'GRN-$year-';
    final rows = await guard(
      () => _client
          .from('goods_in_receipts')
          .select('receipt_code')
          .eq('org_id', _org)
          .like('receipt_code', '$prefix%')
          .order('receipt_code', ascending: false)
          .limit(1),
    );
    final last = rows.isEmpty ? null : rows.first['receipt_code'] as String?;
    final lastSeq = last == null ? 0 : int.tryParse(last.substring(prefix.length)) ?? 0;
    return '$prefix${(lastSeq + 1).toString().padLeft(5, '0')}';
  }

  /// Take custody of a client's stone.
  ///
  /// This is the critical gap in the mockups: "Verified & Logged in Inventory" was a status chip
  /// with no declared value, no verifier identity, no timestamp, no receipt id and no risk
  /// acknowledgement behind it. The shop accepted a $12,500 diamond with no record of what it
  /// had taken.
  ///
  /// All five are required here and the first three are `not null` in the schema: the declared
  /// value, the verifier ([_actor] — never a name typed into a box), the timestamp, the receipt
  /// code and the risk acknowledgement. Photographs, a signature and an insurance reference are
  /// not refused when absent, because a client can be standing at the counter before the camera
  /// is ready — [GoodsInReceipt.missingEvidence] is what chases those afterwards.
  Future<GoodsInReceipt> recordGoodsIn({
    required String jobId,
    required String description,
    required Money declaredValue,
    required bool riskAck,
    String? receiptCode,
    String? customerId,
    List<String> photoIds = const <String>[],
    String? certId,
    String? customerSigId,
    String? insuranceRef,
    String? note,
    DateTime? receivedAt,
  }) async {
    final what = description.trim();
    if (what.isEmpty) {
      throw const RuleViolation(
        message: 'Describe what you are taking in — "1.52 ct oval, GIA 2185… , client ring box". '
            'This is the line a claim would be read against.',
        code: 'custody_no_description',
      );
    }
    if (declaredValue.minor <= 0) {
      throw const RuleViolation(
        message: 'Enter the value the client declares. Custody without a declared value is not '
            'insurable and not defensible.',
        code: 'custody_no_value',
      );
    }
    if (!riskAck) {
      throw const RuleViolation(
        message: 'The client has to accept the risk statement before you can take the goods. '
            'Read it to them and tick it together.',
        code: 'custody_no_risk_ack',
      );
    }

    final supplied = receiptCode?.trim();
    final code =
        supplied == null || supplied.isEmpty ? await suggestReceiptCode() : supplied;

    final row = await guard(
      () => _client
          .from('goods_in_receipts')
          .insert(<String, dynamic>{
            'org_id': _org,
            'job_id': jobId,
            'customer_id': customerId,
            'receipt_code': code,
            'description': what,
            'declared_value': declaredValue.minor,
            'currency': declaredValue.currency,
            // The verifier is the session, not a typed name: a custody record naming someone who
            // was not signed in is worth nothing (D-008).
            'received_by': _actor,
            'received_at': _ts(receivedAt ?? DateTime.now()),
            'customer_sig_id': customerSigId,
            'photo_ids': photoIds,
            'cert_id': certId,
            'risk_ack': riskAck,
            'insurance_ref': insuranceRef?.trim(),
            'note': note?.trim(),
          })
          .select()
          .single(),
    );
    return GoodsInReceipt.fromJson(row);
  }

  /// Attach the evidence a claim would need, after the client has left the counter.
  Future<GoodsInReceipt> updateGoodsInEvidence({
    required String receiptId,
    List<String>? photoIds,
    String? certId,
    String? customerSigId,
    String? insuranceRef,
    String? note,
  }) async {
    final values = <String, dynamic>{
      if (photoIds != null) 'photo_ids': photoIds,
      if (certId != null) 'cert_id': certId,
      if (customerSigId != null) 'customer_sig_id': customerSigId,
      if (insuranceRef != null) 'insurance_ref': _blankToNull(insuranceRef),
      if (note != null) 'note': _blankToNull(note),
    };
    if (values.isEmpty) return _receipt(receiptId);

    final row = await guard(
      () => _client
          .from('goods_in_receipts')
          .update(values)
          .eq('id', receiptId)
          .select()
          .single(),
    );
    return GoodsInReceipt.fromJson(row);
  }

  /// Hand the goods back — finished or not. Closing the custody window is what stops
  /// [GoodsInReceipt.isInCustody] reading true forever.
  Future<GoodsInReceipt> returnGoods({
    required String receiptId,
    String? note,
  }) async {
    final row = await guard(
      () => _client
          .from('goods_in_receipts')
          .update(<String, dynamic>{
            'returned_at': _now(),
            if (note != null) 'note': _blankToNull(note),
          })
          .eq('id', receiptId)
          .select()
          .single(),
    );
    return GoodsInReceipt.fromJson(row);
  }

  Future<GoodsInReceipt> _receipt(String receiptId) async {
    final row = await guard(
      () => _client.from('goods_in_receipts').select().eq('id', receiptId).single(),
    );
    return GoodsInReceipt.fromJson(row);
  }

  // -------------------------------------------------------------- plumbing

  /// Metal is weighed, a serialised stone is counted. A wrong default here would print '124.5 pc
  /// of 18K Gold' on a stock list.
  Uom _defaultUom(StockKind kind) => switch (kind) {
        StockKind.metalBulk => Uom.gram,
        StockKind.stoneSerialized => Uom.piece,
        StockKind.consumable => Uom.piece,
      };

  RecordNotFound _itemGone(String itemId) => RecordNotFound(
        message: 'That stock item is no longer in the vault list, or it is not yours to see.',
        detail: 'item=$itemId',
        code: 'item_missing',
      );

  /// PostgREST's `or` filter is comma-separated and dot-delimited, so a comma, a parenthesis or
  /// a quote in the operator's search term would be read as filter syntax rather than as text.
  /// `%` and `*` are dropped for the same reason: a stray wildcard turns a code search into a
  /// full scan.
  String _searchTerm(String raw) =>
      raw.replaceAll(RegExp(r'[,()"\\%*]'), ' ').trim();

  String _now() => DateTime.now().toUtc().toIso8601String();

  String _ts(DateTime value) => value.toUtc().toIso8601String();

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

// ---------------------------------------------------------------- providers

@Riverpod(keepAlive: true)
InventoryRepository inventoryRepository(Ref ref) => InventoryRepository(
      ref.watch(supabaseProvider),
      ref.watch(repoIdentityProvider),
    );

/// The vault list. The filter arguments are the family key, so changing a filter is a new
/// request rather than a client-side re-sort of a truncated page.
@riverpod
Future<List<InventoryItem>> inventoryStock(
  Ref ref, {
  StockKind? kind,
  String? search,
  StoneOrigin? origin,
  bool inStockOnly = false,
  bool needsReorderOnly = false,
}) =>
    ref.watch(inventoryRepositoryProvider).availableStock(
          kind: kind,
          search: search,
          origin: origin,
          inStockOnly: inStockOnly,
          needsReorderOnly: needsReorderOnly,
        );

@riverpod
Future<InventoryItem?> inventoryItem(Ref ref, String itemId) =>
    ref.watch(inventoryRepositoryProvider).itemById(itemId);

@riverpod
Future<List<StockAllocation>> jobAllocations(Ref ref, String jobId) =>
    ref.watch(inventoryRepositoryProvider).allocationsForJob(jobId);

@riverpod
Future<List<StockTransaction>> stockLedger(Ref ref, String itemId) =>
    ref.watch(inventoryRepositoryProvider).ledger(itemId: itemId);

@riverpod
Future<List<GoodsInReceipt>> jobGoodsIn(Ref ref, String jobId) =>
    ref.watch(inventoryRepositoryProvider).receipts(jobId);
