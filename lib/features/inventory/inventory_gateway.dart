/// The vault's read layer: what a stock list, an item and a goods-in counter each need in one
/// shape.
///
/// Why a gateway rather than more methods on `InventoryRepository`: that repository is per-table
/// and deliberately thin, while these surfaces are per-decision. An inventory keeper standing in
/// front of one stone needs the item, its whole movement ledger, who is holding it, the
/// certificate and photograph attachments behind two uuid columns, signed URLs for those files,
/// the supplier's name and the job codes on every movement. A screen that renders four of those
/// nine is telling a half-truth about a ₹12,50,000 diamond.
///
/// `inventory_management` shipped **no JavaScript at all**: its search box, its filter icon and
/// its "Assign" button did nothing, and both stock bars were hardcoded widths with no field
/// behind them. Everything the mockup painted is real here — [VaultFilter] is the search and the
/// facets, [InventoryItem.stockRatio] is the bar, and the bar is simply absent when no reorder
/// level has been set, because an invented threshold is worse than no bar.
library;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/customer_repository.dart';
import 'package:dhanaos/data/repositories/inventory_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/spec_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'inventory_gateway.g.dart';

// ================================================================= filter

/// Everything behind the search box and the filter icon.
///
/// Both were decoration in the mockup. The facets are separated by stock model on purpose: metal
/// is asked about by alloy and purity, a stone by species, origin and shape, and offering a
/// diamond clarity filter over a gold parcel is how a filter panel becomes noise.
///
/// [origin] is a first-class facet rather than a nicety (D-012): a job specified as lab-grown
/// must never be satisfied out of a natural parcel, so an operator has to be able to ask the
/// vault that question directly.
@immutable
final class VaultFilter {
  const VaultFilter({
    this.kind,
    this.search,
    this.baseMetal,
    this.purity,
    this.stoneType,
    this.origin,
    this.shape,
    this.inStockOnly = false,
    this.needsReorderOnly = false,
    this.limit = 120,
  });

  /// Null means every stock model at once. The screen defaults to a kind because the two models
  /// read differently — grams against a threshold versus one unique stone.
  final StockKind? kind;

  /// Matched against `code` and `label` — 'AU-750', 'DIA-9982-A', '18K Gold'.
  final String? search;

  final BaseMetal? baseMetal;
  final MetalPurity? purity;
  final StoneType? stoneType;
  final StoneOrigin? origin;
  final StoneShape? shape;

  /// Hide anything with nothing free. On for an allocation picker, off for a stock-take.
  final bool inStockOnly;

  /// Only items at or below their reorder level — the bar the mockup drew and never filled.
  final bool needsReorderOnly;

  final int limit;

  bool get hasSearch => (search?.trim().isNotEmpty) ?? false;

  /// How many narrowing choices are on, for the "Clear" affordance and for the empty state's
  /// wording. [kind] is excluded: it is the screen's tab, not a filter the operator set.
  int get activeFacets =>
      (baseMetal == null ? 0 : 1) +
      (purity == null ? 0 : 1) +
      (stoneType == null ? 0 : 1) +
      (origin == null ? 0 : 1) +
      (shape == null ? 0 : 1) +
      (inStockOnly ? 1 : 0) +
      (needsReorderOnly ? 1 : 0);

  bool get isNarrowed => activeFacets > 0 || hasSearch;

  /// A facet that belongs to the other stock model is dropped rather than carried invisibly —
  /// a ruby filter left set while the operator is looking at metals would return nothing and
  /// explain nothing.
  VaultFilter forKind(StockKind? next) => VaultFilter(
        kind: next,
        search: search,
        baseMetal: next == StockKind.metalBulk ? baseMetal : null,
        purity: next == StockKind.metalBulk ? purity : null,
        stoneType: next == StockKind.stoneSerialized ? stoneType : null,
        origin: next == StockKind.stoneSerialized ? origin : null,
        shape: next == StockKind.stoneSerialized ? shape : null,
        inStockOnly: inStockOnly,
        needsReorderOnly: needsReorderOnly,
        limit: limit,
      );

  /// `copyWith` cannot express "clear this facet" — a null argument there means "leave it
  /// alone" — so each clear is an explicit flag.
  VaultFilter copyWith({
    String? search,
    bool clearSearch = false,
    BaseMetal? baseMetal,
    bool clearBaseMetal = false,
    MetalPurity? purity,
    bool clearPurity = false,
    StoneType? stoneType,
    bool clearStoneType = false,
    StoneOrigin? origin,
    bool clearOrigin = false,
    StoneShape? shape,
    bool clearShape = false,
    bool? inStockOnly,
    bool? needsReorderOnly,
    int? limit,
  }) =>
      VaultFilter(
        kind: kind,
        search: clearSearch ? null : (search ?? this.search),
        baseMetal: clearBaseMetal ? null : (baseMetal ?? this.baseMetal),
        // Purity depends on the alloy (D-012: 22K rose gold is not a product), so changing the
        // metal drops a purity that no longer applies.
        purity: clearPurity || clearBaseMetal
            ? null
            : _purityFor(baseMetal ?? this.baseMetal, purity ?? this.purity),
        stoneType: clearStoneType ? null : (stoneType ?? this.stoneType),
        origin: clearOrigin ? null : (origin ?? this.origin),
        shape: clearShape ? null : (shape ?? this.shape),
        inStockOnly: inStockOnly ?? this.inStockOnly,
        needsReorderOnly: needsReorderOnly ?? this.needsReorderOnly,
        limit: limit ?? this.limit,
      );

  static MetalPurity? _purityFor(BaseMetal? metal, MetalPurity? purity) {
    if (metal == null || purity == null) return purity;
    return metal.purities.contains(purity) ? purity : null;
  }

  /// Keep the kind and the search term; drop every facet. Clearing a chip should not also wipe
  /// what the operator typed.
  VaultFilter cleared() => VaultFilter(kind: kind, search: search, limit: limit);

  @override
  bool operator ==(Object other) =>
      other is VaultFilter &&
      other.kind == kind &&
      other.search == search &&
      other.baseMetal == baseMetal &&
      other.purity == purity &&
      other.stoneType == stoneType &&
      other.origin == origin &&
      other.shape == shape &&
      other.inStockOnly == inStockOnly &&
      other.needsReorderOnly == needsReorderOnly &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(
        kind,
        search,
        baseMetal,
        purity,
        stoneType,
        origin,
        shape,
        inStockOnly,
        needsReorderOnly,
        limit,
      );
}

// ================================================================= vault list

/// One page of the vault, plus the reorder picture that page cannot see.
final class VaultPage {
  const VaultPage({
    required this.items,
    required this.lowStock,
    required this.filter,
  });

  /// The page, ordered by code server-side. `v_inventory_available` computes `qty_available`
  /// and `needs_reorder` in SQL, so those are filtered before the truncation rather than after.
  final List<InventoryItem> items;

  /// Everything at or below its reorder level, whatever the current facets — read separately so
  /// a keeper filtering for rubies still sees that the 18K gold is nearly out.
  final List<InventoryItem> lowStock;

  final VaultFilter filter;

  bool get isEmpty => items.isEmpty;

  int countOf(StockKind kind) => items.where((i) => i.kind == kind).length;

  /// Value on hand for the page, but only when every priced item agrees on a currency — [Money]
  /// refuses to add INR to USD, and a total that quietly mixes them is worse than no total.
  Money? get pageValue {
    final priced = [for (final item in items) if (item.onHandValue != null) item];
    if (priced.isEmpty) return null;
    final currency = priced.first.currency;
    if (priced.any((item) => item.currency != currency)) return null;
    var total = Money(0, currency);
    for (final item in priced) {
      total += item.onHandValue!;
    }
    return total;
  }

  /// True when some items carry no unit cost, so the screen can say the total is partial rather
  /// than let a keeper read it as the whole vault.
  bool get valueIsPartial => items.any((item) => item.unitCost == null);
}

// ================================================================= one item

/// Everything `item_screen.dart` renders about one line of stock.
final class ItemDetail {
  const ItemDetail({
    required this.item,
    required this.ledger,
    required this.allocations,
    required this.jobCodes,
    required this.people,
    required this.suppliers,
    this.photo,
    this.certificate,
    this.photoUrl,
    this.certificateUrl,
  });

  final InventoryItem item;

  /// Append-only movements, newest first. UPDATE and DELETE are revoked in Postgres, so this
  /// list is the whole truth about the balance above it.
  final List<StockTransaction> ledger;

  /// Every reservation ever made against the item, open and released, newest first. A released
  /// one still answers "who had it last week".
  final List<StockAllocation> allocations;

  /// jobId -> 'DH-2026-01842'. A ledger row that names a uuid is unusable at a bench.
  final Map<String, String> jobCodes;

  /// Who posted the movement, who made the reservation.
  final Map<String, AppUser> people;

  final Map<String, Partner> suppliers;

  final Attachment? photo;
  final Attachment? certificate;

  /// Signed and short-lived. A public URL would outlive the stone.
  final String? photoUrl;
  final String? certificateUrl;

  List<StockAllocation> get openAllocations =>
      [for (final a in allocations) if (a.isOpen) a];

  /// Reserved and still on the shelf — stock another job cannot have and nobody has pulled.
  List<StockAllocation> get reservations =>
      [for (final a in allocations) if (a.isReservedOnly) a];

  String jobCode(String? jobId) =>
      jobId == null ? '—' : (jobCodes[jobId] ?? jobId.substring(0, 8));

  String? personName(String? userId) => userId == null ? null : people[userId]?.fullName;

  String? supplierName(String? partnerId) =>
      partnerId == null ? null : suppliers[partnerId]?.name;

  double _sum(bool Function(StockTransaction) test) {
    var total = 0.0;
    for (final row in ledger) {
      if (test(row)) total += row.qty;
    }
    return total;
  }

  /// The four reconciliation figures. Jewellery manufacturing loses measurable metal to filings,
  /// polishing and casting sprues, and the mockup's own dashboard raised "Melee diamonds count
  /// mismatch at receiving" while offering nothing that could record a movement — so scrap and
  /// adjustment totals are on the screen, not buried in the ledger.
  double get received => _sum((r) => r.kind == StockTxnKind.receive);
  double get issued => _sum((r) => r.kind == StockTxnKind.issue).abs();
  double get returned => _sum((r) => r.kind == StockTxnKind.returned);
  double get scrapped => _sum((r) => r.kind == StockTxnKind.scrap).abs();

  /// Signed: negative is a shortfall the count found, positive is a find.
  double get adjusted => _sum((r) => r.kind == StockTxnKind.adjust);

  bool get hasLoss => scrapped > 0 || adjusted < 0;

  /// Loss as a share of everything ever received. The figure a month-end reconciliation argues
  /// about, and the one no mockup could have produced.
  double? get lossRatio {
    if (received <= 0) return null;
    final loss = scrapped + (adjusted < 0 ? -adjusted : 0);
    return loss / received;
  }
}

// ================================================================= goods in

/// What the goods-in counter needs before it can take a client's stone.
///
/// Absent from every one of the 46 mockups. `customer_supplied` rendered "Verified & Logged in
/// Inventory" as a status chip with no declared value, no verifier, no timestamp, no receipt id
/// and no risk acknowledgement behind it — so the shop accepted a client's diamond with no
/// record of what it had taken. That is the gap this bundle exists to close.
final class GoodsInContext {
  const GoodsInContext({
    required this.job,
    required this.stones,
    required this.receipts,
    required this.suggestedCode,
    required this.files,
    required this.fileUrls,
    this.customer,
    this.verifierId,
    this.verifierName,
  });

  final Job job;
  final Customer? customer;

  /// The client-supplied stone lines on the job. A receipt can be tied to one of them, which is
  /// what makes the intake step's custody gate pass (`SpecRepository.recordCustody`).
  final List<Stone> stones;

  /// Receipts already taken on this job, newest first.
  final List<GoodsInReceipt> receipts;

  /// 'GRN-2026-00184'. The unique index is the arbiter; a collision surfaces as a
  /// [DuplicateRecord] and the operator takes the next suggestion.
  final String suggestedCode;

  /// Condition photographs, signatures and certificates behind the receipts' uuid columns.
  final Map<String, Attachment> files;
  final Map<String, String> fileUrls;

  /// D-008: the verifier is the signed-in operator and nobody else. A custody record naming
  /// someone who was not signed in is worth nothing, so this is never a typed name.
  final String? verifierId;
  final String? verifierName;

  /// The job's currency governs the declared value — `stones` carries no currency column, and
  /// storing 4,850 paise as 4,850 cents is a silent eighty-fold error on an insurance figure.
  String get currency => job.currency;

  Money get zero => Money(0, currency);

  List<GoodsInReceipt> get inCustody =>
      [for (final r in receipts) if (r.isInCustody) r];

  /// Client-supplied stone lines with no custody block yet — the queue this screen works
  /// through.
  List<Stone> get stonesAwaitingRecord =>
      [for (final s in stones) if (s.needsCustodyRecord) s];

  /// Total the shop is holding for this client. Every receipt on a job shares the job's
  /// currency, so this always adds.
  Money get valueInCustody {
    var total = zero;
    for (final receipt in inCustody) {
      if (receipt.currency == currency) total += receipt.declaredValue;
    }
    return total;
  }

  /// Receipts whose evidence is still incomplete — a photograph or a signature that was not
  /// taken at the counter. Not a refusal: a client can be standing there before the camera is
  /// ready, and [GoodsInReceipt.missingEvidence] is what chases it afterwards.
  List<GoodsInReceipt> get needingEvidence =>
      [for (final r in inCustody) if (!r.isFullyDocumented) r];

  Attachment? file(String? id) => id == null ? null : files[id];

  String? urlFor(String? id) => id == null ? null : fileUrls[id];

  /// Whether taking custody is even the right act here. `Reset Stone` is the job type that
  /// mounts a client's own materials, but a repair can arrive with the client's piece too, so
  /// this informs rather than blocks.
  bool get jobTypeExpectsCustody => job.takesCustody;
}

// ================================================================= gateway

final class InventoryGateway {
  const InventoryGateway(
    this._client,
    this._identity,
    this._store,
    this._inventory,
    this._jobs,
    this._specs,
    this._customers,
  );

  final SupabaseClient _client;
  final RepoIdentity _identity;
  final AttachmentStore _store;
  final InventoryRepository _inventory;
  final JobRepository _jobs;
  final SpecRepository _specs;
  final CustomerRepository _customers;

  /// The `app_users` columns a name needs. `user_roles` is deliberately not joined: this is for
  /// rendering who moved what, and a role badge is not part of that.
  static const _peopleSelect = 'id, org_id, principal, full_name, title, initials, email, '
      'phone, avatar_path, is_active, created_at';

  /// The reads here are sequential on purpose, as in every other gateway: running them together
  /// with `.wait` would replace a [DhFailure] — which carries the server's own operator-facing
  /// sentence — with a `ParallelWaitError`, and those sentences are the product.
  Future<VaultPage> vault(VaultFilter filter) async {
    final items = await _inventory.availableStock(
      kind: filter.kind,
      search: filter.search,
      baseMetal: filter.baseMetal,
      purity: filter.purity,
      stoneType: filter.stoneType,
      origin: filter.origin,
      shape: filter.shape,
      inStockOnly: filter.inStockOnly,
      needsReorderOnly: filter.needsReorderOnly,
      limit: filter.limit,
    );

    // Asked unfiltered and separately: a keeper narrowed to one species still has to be told the
    // gold is nearly out. When the page already *is* the reorder list, reuse it rather than
    // paying for the same read twice.
    final lowStock = filter.needsReorderOnly
        ? items
        : await _inventory.availableStock(needsReorderOnly: true, limit: 50);

    return VaultPage(items: items, lowStock: lowStock, filter: filter);
  }

  Future<ItemDetail> item(String itemId) async {
    final item = await _inventory.itemById(itemId);
    if (item == null) {
      throw RecordNotFound(
        message: 'That stock item is no longer in the vault list, or it is not yours to see.',
        detail: 'item=$itemId',
        code: 'item_missing',
      );
    }

    final ledger = await _inventory.ledger(itemId: itemId, limit: 200);
    final allocations = await _inventory.allocationsForItem(itemId, openOnly: false);

    final files = await _filesFor(<String?>[item.photoId, item.certPdfId]);
    final photo = item.photoId == null ? null : files[item.photoId];
    final certificate = item.certPdfId == null ? null : files[item.certPdfId];

    final signable = [
      if (photo != null) photo,
      // A certificate is usually a PDF, which has no thumbnail but still has to be openable.
      if (certificate != null) certificate,
    ];
    final urls = signable.isEmpty
        ? const <String, String>{}
        : await _store.signedUrls(signable);

    final jobCodes = await _jobCodesFor(<String?>[
      for (final row in ledger) row.jobId,
      for (final row in allocations) row.jobId,
    ]);

    final people = await _peopleFor(<String?>[
      for (final row in ledger) row.createdBy,
      for (final row in allocations) row.allocatedBy,
    ]);

    final suppliers = await _partnersFor(<String?>[
      item.supplierId,
      for (final row in ledger) row.supplierId,
    ]);

    return ItemDetail(
      item: item,
      ledger: ledger,
      allocations: allocations,
      jobCodes: jobCodes,
      people: people,
      suppliers: suppliers,
      photo: photo,
      certificate: certificate,
      photoUrl: photo == null ? null : urls[photo.id],
      certificateUrl: certificate == null ? null : urls[certificate.id],
    );
  }

  Future<GoodsInContext> goodsIn(String jobId) async {
    final job = await _jobs.getJob(jobId);
    final customer = job.customerId == null
        ? null
        : await _customers.findCustomer(job.customerId!);
    final stones = await _specs.listStones(jobId);
    final receipts = await _inventory.receipts(jobId);
    final suggested = await _inventory.suggestReceiptCode();

    final files = await _filesFor(<String?>[
      for (final receipt in receipts) ...[
        receipt.certId,
        receipt.customerSigId,
        ...receipt.photoIds,
      ],
    ]);
    final images = [for (final file in files.values) if (file.isImage) file];
    final urls = images.isEmpty ? const <String, String>{} : await _store.signedUrls(images);

    return GoodsInContext(
      job: job,
      customer: customer,
      // Only the client's own stones: a needs-sourcing line is not in anyone's care.
      stones: [for (final stone in stones) if (stone.isCustomerSupplied) stone],
      receipts: receipts,
      suggestedCode: suggested,
      files: files,
      fileUrls: urls,
      verifierId: _identity.userId,
      verifierName: _identity.displayName,
    );
  }

  /// The stone lines on a job an allocation could satisfy, best match first.
  ///
  /// The mockup's single "Assign" button implied this and had nothing behind it. A stone line is
  /// only offered when it does not contradict the item: species and origin must agree, because
  /// satisfying a lab-grown line out of a natural parcel is a disclosure failure, not a
  /// substitution (D-012).
  Future<List<Stone>> stoneLinesFor({
    required String jobId,
    required InventoryItem item,
  }) async {
    final stones = await _specs.listStones(jobId);
    final candidates = [
      for (final stone in stones)
        if (_stoneAccepts(stone, item)) stone,
    ];
    candidates.sort((a, b) {
      // An unallocated line first, then by role order (centre before side), then position.
      final byOpen = (a.inventoryItemId == null ? 0 : 1) - (b.inventoryItemId == null ? 0 : 1);
      if (byOpen != 0) return byOpen;
      final byRole = a.role.index.compareTo(b.role.index);
      return byRole != 0 ? byRole : a.position.compareTo(b.position);
    });
    return candidates;
  }

  static bool _stoneAccepts(Stone stone, InventoryItem item) {
    if (stone.stoneType != null && item.stoneType != null && stone.stoneType != item.stoneType) {
      return false;
    }
    if (stone.origin != null && item.stoneOrigin != null && stone.origin != item.stoneOrigin) {
      return false;
    }
    return true;
  }

  Future<Map<String, Attachment>> _filesFor(Iterable<String?> ids) async {
    final wanted = <String>{for (final id in ids) if (id != null) id};
    if (wanted.isEmpty) return const <String, Attachment>{};
    final rows = await guard(
      () => _client.from('attachments').select().inFilter('id', wanted.toList()),
    );
    final out = <String, Attachment>{};
    for (final row in rows) {
      final file = Attachment.fromJson(row);
      out[file.id] = file;
    }
    return out;
  }

  /// jobId -> display code. D-001: `coalesce(code, draft_code)` is what a list must show, so
  /// both columns are read and resolved here rather than rendering a raw uuid.
  Future<Map<String, String>> _jobCodesFor(Iterable<String?> ids) async {
    final wanted = <String>{for (final id in ids) if (id != null) id};
    if (wanted.isEmpty) return const <String, String>{};
    final rows = await guard(
      () => _client
          .from('jobs')
          .select('id, code, draft_code')
          .inFilter('id', wanted.toList()),
    );
    final out = <String, String>{};
    for (final row in rows) {
      final id = row['id'] as String;
      out[id] = (row['code'] ?? row['draft_code'] ?? id) as String;
    }
    return out;
  }

  Future<Map<String, AppUser>> _peopleFor(Iterable<String?> ids) async {
    final wanted = <String>{for (final id in ids) if (id != null) id};
    if (wanted.isEmpty) return const <String, AppUser>{};
    final rows = await guard(
      () => _client.from('app_users').select(_peopleSelect).inFilter('id', wanted.toList()),
    );
    final out = <String, AppUser>{};
    for (final row in rows) {
      final user = AppUser.fromJson(row);
      out[user.id] = user;
    }
    return out;
  }

  Future<Map<String, Partner>> _partnersFor(Iterable<String?> ids) async {
    final wanted = <String>{for (final id in ids) if (id != null) id};
    if (wanted.isEmpty) return const <String, Partner>{};
    final rows = await guard(
      () => _client.from('partners').select().inFilter('id', wanted.toList()),
    );
    final out = <String, Partner>{};
    for (final row in rows) {
      final partner = Partner.fromJson(row);
      out[partner.id] = partner;
    }
    return out;
  }
}

// ================================================================= providers

@Riverpod(keepAlive: true)
InventoryGateway inventoryGateway(Ref ref) => InventoryGateway(
      ref.watch(supabaseProvider),
      ref.watch(repoIdentityProvider),
      ref.watch(attachmentStoreProvider),
      ref.watch(inventoryRepositoryProvider),
      ref.watch(jobRepositoryProvider),
      ref.watch(specRepositoryProvider),
      ref.watch(customerRepositoryProvider),
    );

/// The live filter behind the vault list.
///
/// Kept alive on purpose: a keeper who opens a stone, posts a movement and comes back expects
/// the same facets they left set. Metals lead because that is the stock model with a threshold
/// to watch.
@Riverpod(keepAlive: true)
class VaultFilterController extends _$VaultFilterController {
  @override
  VaultFilter build() => const VaultFilter(kind: StockKind.metalBulk);

  void setKind(StockKind? kind) => state = state.forKind(kind);

  void setSearch(String? term) {
    final trimmed = term?.trim();
    state = trimmed == null || trimmed.isEmpty
        ? state.copyWith(clearSearch: true)
        : state.copyWith(search: trimmed);
  }

  void setBaseMetal(BaseMetal? metal) => state = metal == null
      ? state.copyWith(clearBaseMetal: true)
      : state.copyWith(baseMetal: metal);

  void setPurity(MetalPurity? purity) => state =
      purity == null ? state.copyWith(clearPurity: true) : state.copyWith(purity: purity);

  void setStoneType(StoneType? type) => state =
      type == null ? state.copyWith(clearStoneType: true) : state.copyWith(stoneType: type);

  /// D-012 — the facet that must never be quietly dropped.
  void setOrigin(StoneOrigin? origin) => state =
      origin == null ? state.copyWith(clearOrigin: true) : state.copyWith(origin: origin);

  void setShape(StoneShape? shape) =>
      state = shape == null ? state.copyWith(clearShape: true) : state.copyWith(shape: shape);

  void setInStockOnly({required bool value}) => state = state.copyWith(inStockOnly: value);

  void setNeedsReorderOnly({required bool value}) =>
      state = state.copyWith(needsReorderOnly: value);

  void clearFacets() => state = state.cleared();
}

/// One page of the vault. The filter is the family key, so changing a facet is a new request
/// rather than a client-side re-sort of a list the server already truncated.
@riverpod
Future<VaultPage> vaultPage(Ref ref, VaultFilter filter) =>
    ref.watch(inventoryGatewayProvider).vault(filter);

@riverpod
Future<ItemDetail> itemDetail(Ref ref, String itemId) =>
    ref.watch(inventoryGatewayProvider).item(itemId);

@riverpod
Future<GoodsInContext> goodsInContext(Ref ref, String jobId) =>
    ref.watch(inventoryGatewayProvider).goodsIn(jobId);

/// Stone lines on [jobId] that [item] could satisfy. Keyed by both, so the allocate sheet
/// re-asks when either changes.
@riverpod
Future<List<Stone>> allocatableStoneLines(
  Ref ref, {
  required String jobId,
  required InventoryItem item,
}) =>
    ref.watch(inventoryGatewayProvider).stoneLinesFor(jobId: jobId, item: item);

/// The committed, open jobs an allocation or an issue can be posted against.
///
/// A draft has no rail and no bench waiting on it, so reserving stock for one would hold stock
/// against work that may never be committed. `firstWhereOrNull` on the result is how the pickers
/// resolve a chosen id without a second read.
@riverpod
Stream<List<JobListItem>> allocatableJobs(Ref ref, String? search) => ref
    .watch(jobRepositoryProvider)
    .watchJobList(
      JobListFilter(
        search: (search?.trim().isEmpty ?? true) ? null : search!.trim(),
        draftScope: DraftScope.committedOnly,
        limit: 40,
      ),
    );

/// Sugar the pickers share: the chosen job out of a loaded page, or null while it is loading.
JobListItem? jobFrom(List<JobListItem> jobs, String? jobId) =>
    jobId == null ? null : jobs.firstWhereOrNull((job) => job.id == jobId);
