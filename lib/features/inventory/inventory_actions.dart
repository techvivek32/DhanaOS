/// Every write the vault makes, in one place, with one busy flag.
///
/// Three rules shape this file.
///
/// **A balance is never written — it is posted.** `qty_on_hand` is maintained by
/// `trg_stock_balance` from `stock_transactions`, and UPDATE and DELETE on that table are revoked
/// in Postgres. So every quantity change here goes through `InventoryRepository.post`, and a
/// mistake is corrected by a compensating movement rather than by an edit. That is not
/// bureaucracy: jewellery manufacturing loses measurable metal to filings, polishing and casting
/// sprues, and the mockup's own dashboard raised "Melee diamonds count mismatch at receiving"
/// while offering nothing that could record a movement.
///
/// **Reserved is not issued.** Allocating holds stock for a job with the stone still on the
/// shelf; issuing is the movement that takes it off the balance. The mockup's single "Assign"
/// button collapsed both into one word and did neither.
///
/// **A custody record is complete or it is not made.** `recordGoodsIn` refuses a missing declared
/// value, a missing description and an unticked risk acknowledgement, each with its own sentence.
/// This layer adds the second half the repository cannot see: when the receipt is tied to a
/// client-supplied stone line, the stone's own custody block is stamped too, so the intake step's
/// gate passes from the same act rather than needing the counter staff to remember a second
/// screen.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/inventory_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/spec_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/inventory/inventory_gateway.dart';

part 'inventory_actions.g.dart';

/// Which vault write is in flight, so a screen spins the control that was actually pressed
/// rather than greying out everything it owns.
enum VaultTask {
  move,
  allocate,
  release,
  issue,
  goodsIn,
  evidence,
  returnGoods,
  editItem,
}

/// Kept alive for the same reason the other action notifiers are: an upload or a movement must
/// survive the keeper flicking to another screen while the round trip is open. An auto-disposed
/// notifier would be torn down under its own `finally`.
@Riverpod(keepAlive: true)
class InventoryActions extends _$InventoryActions {
  /// Null when nothing is in flight.
  @override
  VaultTask? build() => null;

  bool get isBusy => state != null;

  bool isRunning(VaultTask task) => state == task;

  InventoryRepository get _vault => ref.read(inventoryRepositoryProvider);

  SpecRepository get _specs => ref.read(specRepositoryProvider);

  // -------------------------------------------------------------- movements

  /// Post a movement. The only way a balance changes.
  ///
  /// [qty] is a magnitude for every kind except `adjust`, where the sign is the operator's
  /// finding — negative for a shortfall, positive for a find — and is kept.
  Future<StockTransaction> move({
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
    if (!kind.movesStock) {
      // `allocate` and `release` are reservation states, not movements. Posting one would count
      // stock twice against `inv_alloc_sane`.
      throw RuleViolation(
        message: '${kind.label} is a reservation, not a movement. Use Assign to reserve stock '
            'and Issue to take it out of the vault.',
        code: 'txn_not_a_movement',
      );
    }

    state = VaultTask.move;
    try {
      final txn = await _vault.post(
        itemId: itemId,
        kind: kind,
        qty: qty,
        jobId: jobId,
        stage: stage,
        unitCost: unitCost,
        supplierId: supplierId,
        lotRef: lotRef,
        reference: reference,
        note: note,
      );
      return txn;
    } finally {
      state = null;
      _refreshItem(itemId);
      if (jobId != null) _refreshJob(jobId);
    }
  }

  /// A stock-take correction. The reason is required by the repository, because an unexplained
  /// adjustment is indistinguishable from a loss six weeks later.
  Future<StockTransaction> adjust({
    required String itemId,
    required double delta,
    required String note,
    String? reference,
  }) async {
    state = VaultTask.move;
    try {
      return await _vault.adjust(
        itemId: itemId,
        delta: delta,
        note: note,
        reference: reference,
      );
    } finally {
      state = null;
      _refreshItem(itemId);
    }
  }

  // -------------------------------------------------------------- allocation

  /// Reserve stock against a job — the job picker the mockup's "Assign" button implied and did
  /// not have.
  ///
  /// When the reservation satisfies a specific stone line, `stones.inventory_item_id` is written
  /// too. Without it [Stone.awaitingAllocation] stays true and the job screen keeps reporting a
  /// stone as unfound while it sits reserved in the vault.
  Future<StockAllocation> allocate({
    required InventoryItem item,
    required String jobId,
    required double qty,
    String? stoneId,
  }) async {
    state = VaultTask.allocate;
    try {
      final allocation = await _vault.allocate(
        itemId: item.id,
        jobId: jobId,
        qty: qty,
        stoneId: stoneId,
      );
      if (stoneId != null) {
        await _linkStone(stoneId: stoneId, item: item);
      }
      return allocation;
    } finally {
      state = null;
      _refreshItem(item.id);
      _refreshJob(jobId);
    }
  }

  /// Give the reservation back. The stock never left the vault, so no movement is posted — and
  /// the stone line is unlinked again, otherwise the job would keep claiming a stone it no
  /// longer holds.
  Future<StockAllocation> release(StockAllocation allocation) async {
    state = VaultTask.release;
    try {
      final released = await _vault.releaseAllocation(allocation.id);
      final stoneId = allocation.stoneId;
      if (stoneId != null) {
        await _specs.updateStone(stoneId, inventoryItemId: const Opt<String>.clear());
      }
      return released;
    } finally {
      state = null;
      _refreshItem(allocation.itemId);
      _refreshJob(allocation.jobId);
    }
  }

  /// Physically pull it from the vault: the allocation is marked issued and the movement that
  /// takes it off the balance is posted. The repository owns the ordering — it clears the
  /// reservation first so `inv_alloc_sane` cannot refuse the last unit with a constraint name.
  Future<StockAllocation> issue(
    StockAllocation allocation, {
    LifecycleStage? stage,
    String? note,
  }) async {
    state = VaultTask.issue;
    try {
      return await _vault.issueAllocation(allocation.id, stage: stage, note: note);
    } finally {
      state = null;
      _refreshItem(allocation.itemId);
      _refreshJob(allocation.jobId);
    }
  }

  // -------------------------------------------------------------- goods in

  /// Take custody of a client's materials.
  ///
  /// The mockups had a "Verified & Logged in Inventory" chip and captured none of this. Five
  /// things are required and three of them are `not null` in the schema: the declared value, the
  /// verifier (the session — never a typed name, D-008), the timestamp, the receipt code and the
  /// risk acknowledgement.
  ///
  /// [stoneId] stamps the same facts onto the stone line, which is what makes the intake step's
  /// custody gate pass. If that second write is refused the receipt still stands: the shop has
  /// the goods either way, and a receipt rolled back because a stone row disagreed would be a
  /// custody record destroyed to keep a form tidy. The refusal is re-thrown so the operator is
  /// told which half needs attention.
  Future<GoodsInReceipt> recordGoodsIn({
    required String jobId,
    required String description,
    required Money declaredValue,
    required bool riskAck,
    String? receiptCode,
    String? customerId,
    String? stoneId,
    List<String> photoIds = const <String>[],
    String? certId,
    String? customerSigId,
    String? insuranceRef,
    String? note,
    DateTime? receivedAt,
  }) async {
    state = VaultTask.goodsIn;
    GoodsInReceipt? receipt;
    try {
      receipt = await _vault.recordGoodsIn(
        jobId: jobId,
        description: description,
        declaredValue: declaredValue,
        riskAck: riskAck,
        receiptCode: receiptCode,
        customerId: customerId,
        photoIds: photoIds,
        certId: certId,
        customerSigId: customerSigId,
        insuranceRef: insuranceRef,
        note: note,
        receivedAt: receivedAt,
      );

      if (stoneId != null) {
        await _specs.recordCustody(
          stoneId: stoneId,
          declaredValue: declaredValue,
          receiptCode: receipt.receiptCode,
          riskAck: riskAck,
          verifiedAt: receipt.receivedAt,
        );
      }
      return receipt;
    } on DhFailure catch (failure, stack) {
      final made = receipt;
      if (made == null) rethrow;
      Error.throwWithStackTrace(
        RuleViolation(
          message: 'Receipt ${made.receiptCode} is recorded and the goods are logged, but the '
              'stone line on this job was not updated: ${failure.message}',
          detail: failure.detail,
          code: failure.code,
        ),
        stack,
      );
    } finally {
      state = null;
      _refreshJob(jobId);
    }
  }

  /// Attach the evidence a claim would need, after the client has left the counter.
  Future<GoodsInReceipt> attachEvidence({
    required GoodsInReceipt receipt,
    List<String>? photoIds,
    String? certId,
    String? customerSigId,
    String? insuranceRef,
    String? note,
  }) async {
    state = VaultTask.evidence;
    try {
      return await _vault.updateGoodsInEvidence(
        receiptId: receipt.id,
        photoIds: photoIds,
        certId: certId,
        customerSigId: customerSigId,
        insuranceRef: insuranceRef,
        note: note,
      );
    } finally {
      state = null;
      _refreshJob(receipt.jobId);
    }
  }

  /// Hand the goods back — finished or not. Closing the window is what stops
  /// [GoodsInReceipt.isInCustody] reading true forever, which is the difference between a
  /// register and a shelf of unexplained boxes.
  Future<GoodsInReceipt> returnGoods({
    required GoodsInReceipt receipt,
    String? note,
  }) async {
    state = VaultTask.returnGoods;
    try {
      return await _vault.returnGoods(receiptId: receipt.id, note: note);
    } finally {
      state = null;
      _refreshJob(receipt.jobId);
    }
  }

  // -------------------------------------------------------------- item edits

  /// The descriptive side of an item: where it lives, what it is worth, what the certificate
  /// says. Quantities are absent on purpose — they move through [move].
  Future<InventoryItem> editItem({
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
  }) async {
    state = VaultTask.editItem;
    try {
      return await _vault.updateItem(
        itemId: itemId,
        label: label,
        reorderLevel: reorderLevel,
        stoneOrigin: stoneOrigin,
        attrs: attrs,
        certLab: certLab,
        certNumber: certNumber,
        certPdfId: certPdfId,
        unitCost: unitCost,
        supplierId: supplierId,
        lotRef: lotRef,
        location: location,
        photoId: photoId,
      );
    } finally {
      state = null;
      _refreshItem(itemId);
    }
  }

  // -------------------------------------------------------------- plumbing

  /// Point the stone line at the item it is now satisfied from, and carry the item's origin over
  /// when the line never had one.
  ///
  /// D-012: `origin` survived in exactly one of 46 mockups. Allocating a natural stone to a line
  /// that never stated an origin is the moment the fact is known, so it is written then rather
  /// than left blank for a certificate to contradict later.
  Future<void> _linkStone({required String stoneId, required InventoryItem item}) async {
    final stone = await _specs.getStone(stoneId);
    final origin = item.stoneOrigin;
    await _specs.updateStone(
      stoneId,
      inventoryItemId: Opt(item.id),
      sourcing: stone.sourcing == StoneSourcing.inStock
          ? null
          : const Opt(StoneSourcing.inStock),
      origin: stone.origin == null && origin != null ? Opt(origin) : null,
      stoneType: stone.stoneType == null && item.stoneType != null
          ? Opt(item.stoneType!)
          : null,
    );
  }

  void _refreshItem(String itemId) {
    ref.invalidate(itemDetailProvider(itemId));
    ref.invalidate(inventoryItemProvider(itemId));
    ref.invalidate(stockLedgerProvider(itemId));
    // The list's filter is not known here, and every filter's page can be stale after a
    // movement — a balance crossing its reorder level changes which page a row belongs on.
    ref.invalidate(vaultPageProvider);
    ref.invalidate(inventoryStockProvider);
  }

  void _refreshJob(String jobId) {
    ref.invalidate(jobAllocationsProvider(jobId));
    ref.invalidate(jobGoodsInProvider(jobId));
    ref.invalidate(goodsInContextProvider(jobId));
    ref.invalidate(jobStonesProvider(jobId));
    ref.invalidate(stoneGapsProvider(jobId));
    ref.invalidate(allocatableStoneLinesProvider);
  }
}
