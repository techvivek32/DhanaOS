/// Dart mirrors of the Postgres enums in `supabase/migrations/0001_enums.sql`.
///
/// `wire` is the exact Postgres value — never rename one without a migration.
/// `label` is what an operator reads. Several of these carry provenance notes because the
/// mockups shipped competing vocabularies; see DECISIONS.md.
library;

/// Resolve an enum from its Postgres wire value, falling back when the database is ahead
/// of the app (an added enum value must not crash a running build).
T? _from<T>(List<T> values, String? wire, String Function(T) key) {
  if (wire == null) return null;
  for (final v in values) {
    if (key(v) == wire) return v;
  }
  return null;
}

// ---------------------------------------------------------------- lifecycle (D-002)

/// The canonical 14-stage rail from `job_detail_dh_1048`. The dashboard's 8 counters are a
/// derived view over these (see `v_stage_counters`), never a second enum.
enum LifecycleStage {
  inquiry('inquiry', 'Inquiry'),
  cad('cad', 'CAD'),
  approval('approval', 'Approval'),
  pricing('pricing', 'Pricing'),
  finalApp('final_app', 'Final App'),
  wax('wax', 'Wax'),
  casting('casting', 'Casting'),
  assembly('assembly', 'Assembly'),
  setting('setting', 'Setting'),
  polishing('polishing', 'Polishing'),
  qc('qc', 'QC'),
  cert('cert', 'Cert'),
  dispatch('dispatch', 'Dispatch'),
  delivered('delivered', 'Delivered');

  const LifecycleStage(this.wire, this.label);
  final String wire;
  final String label;

  int get seq => index + 1;

  /// The 8 stages the dashboard counts. Their sum is "Total Active" by construction.
  static const operational = [
    cad, approval, wax, casting, assembly, setting, qc, cert,
  ];

  /// Stages an external partner can be assigned to.
  bool get isPartnerStage => this == casting || this == cert;

  static LifecycleStage? parse(String? w) =>
      _from(values, w, (e) => e.wire);
}

enum StageState {
  pending('pending', 'Pending'),
  active('active', 'Active'),
  completed('completed', 'Completed'),
  skipped('skipped', 'Skipped'),
  blocked('blocked', 'Blocked');

  const StageState(this.wire, this.label);
  final String wire;
  final String label;
  static StageState? parse(String? w) => _from(values, w, (e) => e.wire);
}

/// D-006 — `onHold`, `rework` and `cancelled` did not exist in any mockup. Every gate there
/// was one-way. They ship in Phase 2 because retrofitting states into a live append-only
/// audit log is far worse than defining them up front.
enum JobStatus {
  draft('draft', 'Draft'),
  pendingApproval('pending_approval', 'Pending Approval'),
  approvedReady('approved_ready', 'Approved · Ready'),
  inProduction('in_production', 'In Production'),
  onHold('on_hold', 'On Hold'),
  rework('rework', 'Rework'),
  cancelled('cancelled', 'Cancelled'),
  completed('completed', 'Completed'),
  archived('archived', 'Archived');

  const JobStatus(this.wire, this.label);
  final String wire;
  final String label;
  bool get isOpen => this != completed && this != cancelled && this != archived;
  static JobStatus? parse(String? w) => _from(values, w, (e) => e.wire);
}

// ---------------------------------------------------------------- job shape

/// Export B offered four; export C dropped `repair`. D-012 keeps B's superset because
/// repair and sizing is real shop revenue.
enum JobType {
  newCustomDesign('new_custom_design', 'New Custom Design', 'Start a fresh CAD from sketch'),
  recreateExisting('recreate_existing', 'Recreate Existing', 'Duplicate or repair a piece'),
  resetStone('reset_stone', 'Reset Stone', 'Mounting customer materials'),
  repair('repair', 'Repair', 'Restoration or sizing services');

  const JobType(this.wire, this.label, this.blurb);
  final String wire;
  final String label;
  final String blurb;

  /// Mounting a client's own stone always opens the goods-in custody flow.
  bool get takesCustody => this == resetStone;

  static JobType? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum ProductCategory {
  ring('ring', 'Ring'),
  earrings('earrings', 'Earrings'),
  necklace('necklace', 'Necklace'),
  pendant('pendant', 'Pendant'),
  bracelet('bracelet', 'Bracelet'),
  bangle('bangle', 'Bangle'),
  brooch('brooch', 'Brooch'),
  other('other', 'Other');

  const ProductCategory(this.wire, this.label);
  final String wire;
  final String label;

  /// D-012: the mockups hardcoded ring-only fields with no conditional swap. Ring size and
  /// band width apply here; everything else needs its own dimension set.
  bool get usesRingSize => this == ring;
  bool get usesInnerDiameter => this == bangle || this == bracelet;
  bool get usesLength => this == necklace || this == bracelet;
  bool get usesDrop => this == earrings || this == pendant;

  static ProductCategory? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum Priority {
  standard('standard', 'Standard'),
  rush('rush', 'Rush'),
  critical('critical', 'Critical');

  const Priority(this.wire, this.label);
  final String wire;
  final String label;
  static Priority? parse(String? w) => _from(values, w, (e) => e.wire);
}

// ---------------------------------------------------------------- metal

enum BaseMetal {
  gold('gold', 'Gold'),
  platinum('platinum', 'Platinum'),
  silver('silver', 'Silver'),
  palladium('palladium', 'Palladium'),
  other('other', 'Other');

  const BaseMetal(this.wire, this.label);
  final String wire;
  final String label;

  /// D-012: the mockups shipped a flat purity list with no dependency on base metal — so
  /// 22K rose gold was selectable, which is not a product. This is that dependency.
  List<MetalPurity> get purities => switch (this) {
        gold => const [MetalPurity.k9, MetalPurity.k14, MetalPurity.k18,
                       MetalPurity.k22, MetalPurity.k24],
        platinum => const [MetalPurity.pt900, MetalPurity.pt950],
        silver => const [MetalPurity.s925],
        palladium => const [MetalPurity.pt950],
        other => MetalPurity.values,
      };

  /// Colour only means something for gold.
  bool get hasColor => this == gold;

  static BaseMetal? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum MetalPurity {
  k9('k9', '9K'),
  k14('k14', '14K'),
  k18('k18', '18K'),
  k22('k22', '22K'),
  k24('k24', '24K'),
  pt900('pt900', 'Pt 900'),
  pt950('pt950', 'Pt 950'),
  s925('s925', '925 Silver');

  const MetalPurity(this.wire, this.label);
  final String wire;
  final String label;
  static MetalPurity? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum MetalColor {
  yellow('yellow', 'Yellow'),
  white('white', 'White'),
  rose('rose', 'Rose'),
  twoTone('two_tone', 'Two Tone');

  const MetalColor(this.wire, this.label);
  final String wire;
  final String label;
  static MetalColor? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum MetalFinish {
  highPolish('high_polish', 'High Polish'),
  matteSatin('matte_satin', 'Matte / Satin'),
  hammered('hammered', 'Hammered'),
  brushed('brushed', 'Brushed');

  const MetalFinish(this.wire, this.label);
  final String wire;
  final String label;
  static MetalFinish? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum BandProfile {
  round('round', 'Round'),
  flat('flat', 'Flat'),
  knifeEdge('knife_edge', 'Knife-Edge');

  const BandProfile(this.wire, this.label);
  final String wire;
  final String label;
  static BandProfile? parse(String? w) => _from(values, w, (e) => e.wire);
}

// ---------------------------------------------------------------- design

enum SettingStyle {
  prong('prong', 'Prong'),
  bezel('bezel', 'Bezel'),
  halo('halo', 'Halo'),
  tension('tension', 'Tension'),
  other('other', 'Other');

  const SettingStyle(this.wire, this.label);
  final String wire;
  final String label;

  /// D-012: every "Other" in the mockups was preselected and had no follow-up text field.
  bool get needsDetail => this == other;

  static SettingStyle? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum SideStoneSetting {
  none('none', 'None'),
  pave('pave', 'Pavé'),
  channel('channel', 'Channel'),
  sharedProng('shared_prong', 'Shared Prong');

  const SideStoneSetting(this.wire, this.label);
  final String wire;
  final String label;
  static SideStoneSetting? parse(String? w) => _from(values, w, (e) => e.wire);
}

/// The customer-facing intent question: "What matters most?"
enum DesignIntent {
  matchExactly('match_exactly', 'Match Exactly'),
  showOffStone('show_off_stone', 'Show Off Stone'),
  strongAndSafe('strong_and_safe', 'Strong & Safe'),
  other('other', 'Other Idea');

  const DesignIntent(this.wire, this.label);
  final String wire;
  final String label;
  bool get needsDetail => this == other;
  static DesignIntent? parse(String? w) => _from(values, w, (e) => e.wire);
}

// ---------------------------------------------------------------- stones

enum StoneType {
  diamond('diamond', 'Diamond'),
  sapphire('sapphire', 'Sapphire'),
  ruby('ruby', 'Ruby'),
  emerald('emerald', 'Emerald'),
  moissanite('moissanite', 'Moissanite'),
  other('other', 'Other');

  const StoneType(this.wire, this.label);
  final String wire;
  final String label;

  /// Diamond and moissanite are graded on the 4Cs; coloured stones are not.
  bool get usesFourCs => this == diamond || this == moissanite;

  static StoneType? parse(String? w) => _from(values, w, (e) => e.wire);
}

/// D-012 — the field to watch. Survived in exactly ONE file out of 46 mockups; every later
/// redesign silently dropped it. Natural vs lab-grown changes valuation, disclosure
/// obligations and certification, so it is never optional in the UI.
enum StoneOrigin {
  natural('natural', 'Natural'),
  labGrown('lab_grown', 'Lab Grown');

  const StoneOrigin(this.wire, this.label);
  final String wire;
  final String label;
  static StoneOrigin? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum StoneShape {
  roundBrilliant('round_brilliant', 'Round Brilliant'),
  oval('oval', 'Oval'),
  pear('pear', 'Pear'),
  emeraldCut('emerald_cut', 'Emerald'),
  radiant('radiant', 'Radiant'),
  cushion('cushion', 'Cushion'),
  marquise('marquise', 'Marquise'),
  princess('princess', 'Princess'),
  asscher('asscher', 'Asscher'),
  heart('heart', 'Heart'),
  baguette('baguette', 'Baguette'),
  other('other', 'Other');

  const StoneShape(this.wire, this.label);
  final String wire;
  final String label;
  static StoneShape? parse(String? w) => _from(values, w, (e) => e.wire);
}

/// D-012 — the mockups' segmented control meant two different things across variants:
/// timing ("Include Now / Include Later") vs sourcing. Resolved to sourcing.
enum StoneSourcing {
  needsSourcing('needs_sourcing', 'Needs Sourcing', 'We source it'),
  inStock('in_stock', 'In Stock', 'Allocate from the vault'),
  customerSupplied('customer_supplied', 'Customer Supplied', 'Client provides the stone');

  const StoneSourcing(this.wire, this.label, this.blurb);
  final String wire;
  final String label;
  final String blurb;

  /// Taking custody requires declared value, verifier, timestamp and receipt — none of which
  /// any mockup captured.
  bool get requiresCustodyRecord => this == customerSupplied;

  static StoneSourcing? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum StoneRole {
  center('center', 'Centre Stone'),
  accent('accent', 'Accent'),
  side('side', 'Side Stone');

  const StoneRole(this.wire, this.label);
  final String wire;
  final String label;
  static StoneRole? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum DiamondColor {
  d('d', 'D'), e('e', 'E'), f('f', 'F'), g('g', 'G'), h('h', 'H'),
  i('i', 'I'), j('j', 'J'), k('k', 'K'), l('l', 'L'), m('m', 'M'),
  other('other', 'Other');

  const DiamondColor(this.wire, this.label);
  final String wire;
  final String label;
  static DiamondColor? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum DiamondClarity {
  fl('fl', 'FL'), ifl('if', 'IF'),
  vvs1('vvs1', 'VVS1'), vvs2('vvs2', 'VVS2'),
  vs1('vs1', 'VS1'), vs2('vs2', 'VS2'),
  si1('si1', 'SI1'), si2('si2', 'SI2'),
  i1('i1', 'I1'), other('other', 'Other');

  const DiamondClarity(this.wire, this.label);
  final String wire;
  final String label;
  static DiamondClarity? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum DiamondCut {
  excellent('excellent', 'Excellent'),
  veryGood('very_good', 'Very Good'),
  good('good', 'Good'),
  fair('fair', 'Fair'),
  poor('poor', 'Poor');

  const DiamondCut(this.wire, this.label);
  final String wire;
  final String label;
  static DiamondCut? parse(String? w) => _from(values, w, (e) => e.wire);
}

// ---------------------------------------------------------------- certification

/// Three disagreeing lists existed across the mockups; this is the union.
enum CertLab {
  gia('gia', 'GIA'),
  igi('igi', 'IGI'),
  hrd('hrd', 'HRD Antwerp'),
  ags('ags', 'AGS'),
  other('other', 'Other'),
  none('none', 'None');

  const CertLab(this.wire, this.label);
  final String wire;
  final String label;

  /// Choosing none must skip the certification stage and zero the delivery buffer — a
  /// cross-screen dependency the mockups declared and never wired.
  bool get skipsStage => this == none;

  static CertLab? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum CertStatus {
  waiting('waiting', 'Waiting'),
  sent('sent', 'Sent'),
  atLab('at_lab', 'At Lab'),
  inProgress('in_progress', 'In Progress'),
  certified('certified', 'Certified'),
  returned('returned', 'Returned'),
  rejected('rejected', 'Rejected');

  const CertStatus(this.wire, this.label);
  final String wire;
  final String label;
  static CertStatus? parse(String? w) => _from(values, w, (e) => e.wire);
}

// ---------------------------------------------------------------- commercial

enum PricingBasis {
  fixed('fixed', 'Fixed'),
  quote('quote', 'Quote'),
  costPlus('cost_plus', 'Cost Plus');

  const PricingBasis(this.wire, this.label);
  final String wire;
  final String label;

  /// Cost Plus must reveal a margin field; Quote must introduce an approval state. Neither
  /// branch existed in the mockups — the three buttons had no JavaScript at all.
  bool get needsMargin => this == costPlus;
  bool get needsApproval => this == quote;

  static PricingBasis? parse(String? w) => _from(values, w, (e) => e.wire);
}

/// D-003 — five customer-facing categories.
enum CostCategory {
  metal('metal', 'Metal'),
  gemstones('gemstones', 'Gemstones'),
  labor('labor', 'Labor'),
  setting('setting', 'Setting'),
  certification('certification', 'Certification');

  const CostCategory(this.wire, this.label);
  final String wire;
  final String label;
  static CostCategory? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum QuoteStatus {
  draft('draft', 'Draft'),
  sent('sent', 'Sent'),
  approved('approved', 'Approved'),
  rejected('rejected', 'Rejected'),
  counterOffered('counter_offered', 'Counter Offered'),
  expired('expired', 'Expired');

  const QuoteStatus(this.wire, this.label);
  final String wire;
  final String label;
  static QuoteStatus? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum ApprovalGateKind {
  designReview('design_review', 'Design Review'),
  costAnalysis('cost_analysis', 'Cost Analysis'),
  vendorAllocation('vendor_allocation', 'Vendor Allocation');

  const ApprovalGateKind(this.wire, this.label);
  final String wire;
  final String label;
  static ApprovalGateKind? parse(String? w) => _from(values, w, (e) => e.wire);

  /// Which role may decide this gate. D-008 puts the enforcement in RLS; this is so the screen
  /// can hide a button the session cannot use.
  UserRole get decidingRole => switch (this) {
        designReview => UserRole.engineer,
        costAnalysis => UserRole.admin,
        vendorAllocation => UserRole.productionManager,
      };
}

// ---------------------------------------------------------------- quality

enum QualityAuthority {
  customer('customer', 'Customer'),
  jeweler('jeweler', 'Jeweler'),
  manufacturer('manufacturer', 'Manufacturer'),
  internalQc('internal_qc', 'Internal QC');

  const QualityAuthority(this.wire, this.label);
  final String wire;
  final String label;

  /// Selecting customer must insert a portal approval gate before QC sign-off. The mockups
  /// offered the option and had no such transition or screen.
  bool get needsCustomerGate => this == customer;

  static QualityAuthority? parse(String? w) => _from(values, w, (e) => e.wire);
}

/// D-006 — `failed` was designed in the mockup's CSS and made unreachable in its JS.
enum QcStatus {
  pending('pending', 'Pending Review'),
  inProgress('in_progress', 'Inspection in Progress'),
  ready('ready', 'Ready for Authorization'),
  approved('approved', 'QC Approved'),
  failed('failed', 'Failed');

  const QcStatus(this.wire, this.label);
  final String wire;
  final String label;
  static QcStatus? parse(String? w) => _from(values, w, (e) => e.wire);
}

// ---------------------------------------------------------------- logistics

enum DispatchRouting {
  jeweler('jeweler', 'Return to Jeweler', 'Standard B2B transfer protocol.'),
  customer('customer', 'Direct to Customer', 'Requires white-glove unboxing prep.');

  const DispatchRouting(this.wire, this.label, this.blurb);
  final String wire;
  final String label;
  final String blurb;
  bool get needsWhiteGlove => this == customer;
  static DispatchRouting? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum Courier {
  brinks('brinks', 'Brinks Secure Logistics', 'High Value'),
  fedex('fedex', 'FedEx Priority Overnight', ''),
  malcaAmit('malca_amit', 'Malca-Amit', 'International'),
  bluedart('bluedart', 'Blue Dart', 'Domestic India'),
  other('other', 'Other', '');

  const Courier(this.wire, this.label, this.note);
  final String wire;
  final String label;
  final String note;

  /// An international courier needs customs and a commercial invoice — neither of which the
  /// mockup's shipping screen had a field for.
  bool get isInternational => this == malcaAmit;

  static Courier? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum ShipmentLeg {
  waxInbound('wax_inbound', 'Wax Inbound'),
  toCaster('to_caster', 'To Caster'),
  fromCaster('from_caster', 'From Caster'),
  toLab('to_lab', 'To Lab'),
  fromLab('from_lab', 'From Lab'),
  finalDispatch('final_dispatch', 'Final Dispatch');

  const ShipmentLeg(this.wire, this.label);
  final String wire;
  final String label;
  static ShipmentLeg? parse(String? w) => _from(values, w, (e) => e.wire);
}

// ---------------------------------------------------------------- identity (D-008)

enum UserRole {
  admin('admin', 'Admin'),
  engineer('engineer', 'Manufacturing Engineer'),
  cadDesigner('cad_designer', 'CAD Designer'),
  productionManager('production_manager', 'Production Manager'),
  qcInspector('qc_inspector', 'QC Inspector'),
  logistics('logistics', 'Logistics'),
  inventoryKeeper('inventory_keeper', 'Inventory Keeper'),
  benchOperator('bench_operator', 'Bench Operator'),
  partner('partner', 'Partner'),
  customer('customer', 'Customer');

  const UserRole(this.wire, this.label);
  final String wire;
  final String label;
  static UserRole? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum PrincipalClass {
  internal('internal'),
  partner('partner'),
  customer('customer');

  const PrincipalClass(this.wire);
  final String wire;
  static PrincipalClass? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum PartnerKind {
  casting('casting', 'Casting'),
  lab('lab', 'Gem Lab'),
  stoneSupplier('stone_supplier', 'Stone Supplier'),
  courier('courier', 'Courier'),
  hub('hub', 'Hub'),
  other('other', 'Other');

  const PartnerKind(this.wire, this.label);
  final String wire;
  final String label;
  static PartnerKind? parse(String? w) => _from(values, w, (e) => e.wire);
}

// ---------------------------------------------------------------- collaboration

enum ActivityKind {
  stageChanged('stage_changed'),
  jobCreated('job_created'),
  assigned('assigned'),
  fileUploaded('file_uploaded'),
  approved('approved'),
  rejected('rejected'),
  comment('comment'),
  exceptionRaised('exception_raised'),
  system('system');

  const ActivityKind(this.wire);
  final String wire;
  static ActivityKind? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum AttachmentKind {
  referenceImage('reference_image', 'Reference'),
  sketch('sketch', 'Sketch'),
  cadFile('cad_file', 'CAD File'),
  cadRender('cad_render', 'CAD Render'),
  stl('stl', 'STL / STEP'),
  stonePhoto('stone_photo', 'Stone Photo'),
  certificatePdf('certificate_pdf', 'Certificate'),
  castingPhoto('casting_photo', 'Casting Photo'),
  qcEvidence('qc_evidence', 'QC Evidence'),
  voiceNote('voice_note', 'Voice Note'),
  invoice('invoice', 'Invoice'),
  proofOfDelivery('proof_of_delivery', 'Proof of Delivery'),
  other('other', 'File');

  const AttachmentKind(this.wire, this.label);
  final String wire;
  final String label;
  static AttachmentKind? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum ActionSeverity {
  info('info'),
  warning('warning'),
  error('error'),
  success('success');

  const ActionSeverity(this.wire);
  final String wire;
  static ActionSeverity? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum StockKind {
  metalBulk('metal_bulk', 'Metal'),
  stoneSerialized('stone_serialized', 'Stone'),
  consumable('consumable', 'Consumable');

  const StockKind(this.wire, this.label);
  final String wire;
  final String label;
  static StockKind? parse(String? w) => _from(values, w, (e) => e.wire);
}

enum Uom {
  gram('gram', 'g'),
  carat('carat', 'ct'),
  piece('piece', 'pc');

  const Uom(this.wire, this.symbol);
  final String wire;
  final String symbol;
  static Uom? parse(String? w) => _from(values, w, (e) => e.wire);
}
