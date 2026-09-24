/// Postgres enums that `lib/domain/enums.dart` does not declare yet.
///
/// Six types in `0001_enums.sql` have no Dart mirror: `product_sub_style`, `fit_profile`,
/// `supplied_by`, `approval_gate_state`, `shipment_status` and `stock_txn_kind`. The models in
/// this folder need all six to type their columns, and a model must never carry a bare wire
/// string (convention 6). They live here — inside the folder that needs them — rather than in
/// `enums.dart`, which this agent does not own.
///
/// If they later land in `enums.dart`, reduce this file to `export` lines; nothing else has to
/// change, because every consumer reaches them through `models.dart`.
///
/// Same contract as `enums.dart`: `wire` is the exact Postgres value, `label` is what an
/// operator reads, and `parse` returns null for an unknown value so a database ahead of the
/// app cannot crash a running build.
library;

import 'package:dhanaos/domain/enums.dart';

T? _from<T>(List<T> values, String? wire, String Function(T) key) {
  if (wire == null) return null;
  for (final v in values) {
    if (key(v) == wire) return v;
  }
  return null;
}

/// `product_selection` showed a flat category list while downstream screens displayed
/// "Engagement Ring" — which is a sub-style, not a category. D-012 splits them, so the
/// sub-style list has to be filtered by the chosen category.
enum ProductSubStyle {
  engagementRing('engagement_ring', 'Engagement Ring'),
  solitaireRing('solitaire_ring', 'Solitaire Ring'),
  haloRing('halo_ring', 'Halo Ring'),
  eternityBand('eternity_band', 'Eternity Band'),
  weddingBand('wedding_band', 'Wedding Band'),
  signetRing('signet_ring', 'Signet Ring'),
  cocktailRing('cocktail_ring', 'Cocktail Ring'),
  stud('stud', 'Stud'),
  hoop('hoop', 'Hoop'),
  drop('drop', 'Drop'),
  chain('chain', 'Chain'),
  choker('choker', 'Choker'),
  tennis('tennis', 'Tennis'),
  other('other', 'Other');

  const ProductSubStyle(this.wire, this.label);
  final String wire;
  final String label;

  /// Which sub-styles a category may take. Offering "Hoop" under Ring is how the mockups'
  /// flat list produced impossible combinations.
  static List<ProductSubStyle> forCategory(ProductCategory category) => switch (category) {
        ProductCategory.ring => const [
            engagementRing, solitaireRing, haloRing, eternityBand,
            weddingBand, signetRing, cocktailRing, other,
          ],
        ProductCategory.earrings => const [stud, hoop, drop, other],
        ProductCategory.necklace => const [chain, choker, tennis, other],
        ProductCategory.pendant => const [drop, other],
        ProductCategory.bracelet => const [chain, tennis, other],
        ProductCategory.bangle => const [other],
        ProductCategory.brooch => const [other],
        ProductCategory.other => values,
      };

  static ProductSubStyle? parse(String? w) => _from(values, w, (e) => e.wire);
}

/// Inner-surface profile. Comfort fit changes the metal weight for the same finger size, so it
/// belongs to the binding spec, not to the finish.
enum FitProfile {
  comfortFit('comfort_fit', 'Comfort Fit'),
  standard('standard', 'Standard'),
  flat('flat', 'Flat');

  const FitProfile(this.wire, this.label);
  final String wire;
  final String label;
  static FitProfile? parse(String? w) => _from(values, w, (e) => e.wire);
}

/// Who owns the material on a cost line. When the client owns it the line carries a declared
/// value for insurance, not a price to charge.
enum SuppliedBy {
  house('house', 'In-House'),
  client('client', 'Client Supplied');

  const SuppliedBy(this.wire, this.label);
  final String wire;
  final String label;

  bool get isClient => this == client;

  static SuppliedBy? parse(String? w) => _from(values, w, (e) => e.wire);
}

/// `review_job_order` showed three gates, all "Pending", with no screen behind any of them.
enum ApprovalGateState {
  pending('pending', 'Pending'),
  approved('approved', 'Approved'),
  rejected('rejected', 'Rejected');

  const ApprovalGateState(this.wire, this.label);
  final String wire;
  final String label;

  bool get isDecided => this != pending;

  static ApprovalGateState? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum ShipmentStatus {
  draft('draft', 'Draft'),
  dispatched('dispatched', 'Dispatched'),
  inTransit('in_transit', 'In Transit'),
  delivered('delivered', 'Delivered'),
  exception('exception', 'Exception');

  const ShipmentStatus(this.wire, this.label);
  final String wire;
  final String label;

  bool get isInFlight => this == dispatched || this == inTransit;

  /// Only a draft leg can be dispatched — re-dispatching a leg already in transit would lose
  /// the first waybill.
  bool get isDispatchable => this == draft;

  static ShipmentStatus? parse(String? w) => _from(values, w, (e) => e.wire);
}

/// Jewellery manufacturing loses measurable metal to filings, polishing and casting sprues,
/// which is why `scrap` is a first-class movement and not an `adjust`.
enum StockTxnKind {
  receive('receive', 'Receive'),
  issue('issue', 'Issue'),
  // `return` is a Dart keyword; only the wire value may read 'return'.
  returned('return', 'Return'),
  adjust('adjust', 'Adjust'),
  scrap('scrap', 'Scrap'),
  allocate('allocate', 'Allocate'),
  release('release', 'Release');

  const StockTxnKind(this.wire, this.label);
  final String wire;
  final String label;

  /// Sign the quantity should carry on `stock_transactions.qty`. `adjust` may be either, so it
  /// reports 0 and the caller keeps the operator's sign.
  int get sign => switch (this) {
        receive || returned => 1,
        issue || scrap => -1,
        adjust || allocate || release => 0,
      };

  bool get movesStock => this != allocate && this != release;

  static StockTxnKind? parse(String? w) => _from(values, w, (e) => e.wire);
}
