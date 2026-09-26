/// The read layer behind `/shipping/<jobId>`: every leg of a job, and everything one leg needs
/// before it can be dispatched or received.
///
/// Why a gateway rather than more methods on `ProductionRepository`: that repository is per-table
/// and deliberately thin, while this surface is per-decision. An operator standing at the packing
/// bench needs the job, its rail, all six possible legs, the partners on the other end of each,
/// the approved quote the declared value comes from, the tax invoice the piece cannot legally
/// ship without (D-004), and the proof-of-delivery files already on the record. A screen that
/// renders four of those eight is showing a half-truth about an irreversible act.
///
/// **The multi-leg shape is the part the mockups got wrong.** `shipping_dispatch` modelled one
/// shipment per job, while the same corpus showed a wax arriving from "Central Hub", a to-lab leg
/// with a FedEx number, a from-lab return, and then the final dispatch — four legs on one job,
/// three of which had nowhere to live. `shipments.leg` is that missing dimension, and
/// [ShippingBundle.legs] is how a screen reads it.
library;

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/customer_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/repositories/quote_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'shipping_gateway.g.dart';

// ================================================================= leg vocabulary

/// True when the goods are coming *in*.
///
/// An inbound leg has no dispatch of ours to confirm — it was dispatched by the hub, the caster
/// or the lab. The mockup's single "Confirm Dispatch" button made no distinction, which is why
/// the wax arriving from "Central Hub" had nowhere at all to be recorded. Here an inbound leg
/// takes a receipt instead, gated on an inspection protocol rather than a seal protocol.
bool isInboundLeg(ShipmentLeg leg) =>
    leg == ShipmentLeg.waxInbound ||
    leg == ShipmentLeg.fromCaster ||
    leg == ShipmentLeg.fromLab;

/// Which partner kind a leg's counterparty is drawn from, or null where the far end is an address
/// rather than a partner — a final dispatch goes to a retailer or a private customer, and neither
/// is a `partners` row.
///
/// Scoping the picker by kind is what stops a courier being chosen as the casting house, one of
/// the impossible combinations the mockups' flat pickers allowed.
PartnerKind? counterpartyKindFor(ShipmentLeg leg) => switch (leg) {
      ShipmentLeg.waxInbound => PartnerKind.hub,
      ShipmentLeg.toCaster || ShipmentLeg.fromCaster => PartnerKind.casting,
      ShipmentLeg.toLab || ShipmentLeg.fromLab => PartnerKind.lab,
      ShipmentLeg.finalDispatch => null,
    };

/// The rail stage a leg belongs to, for tagging the thread post a movement writes.
///
/// D-005: a post tagged to where the job was when it was written still says which stage the
/// remark was about six weeks later.
LifecycleStage stageForLeg(ShipmentLeg leg) => switch (leg) {
      ShipmentLeg.waxInbound => LifecycleStage.wax,
      ShipmentLeg.toCaster || ShipmentLeg.fromCaster => LifecycleStage.casting,
      ShipmentLeg.toLab || ShipmentLeg.fromLab => LifecycleStage.cert,
      ShipmentLeg.finalDispatch => LifecycleStage.dispatch,
    };

// ================================================================= the bundle

/// Every leg of one job, fully loaded.
final class ShippingBundle {
  const ShippingBundle({
    required this.job,
    required this.rail,
    required this.customer,
    required this.shipments,
    required this.partners,
    required this.approvedQuote,
    required this.invoices,
    required this.files,
    required this.fileUrls,
    required this.people,
  });

  final Job job;

  /// D-005: where the job actually is. Confirming the final delivery closes a stage, so the rail
  /// — not `jobs.current_stage` — decides which one.
  final StageRail rail;

  /// Null on a job with no customer yet, which is also what blocks the tax invoice.
  final Customer? customer;

  /// Every leg ever opened on the job, oldest first within each leg kind.
  final List<Shipment> shipments;

  /// Every partner referenced by a leg, keyed by id. D-008: a name on screen came off a row.
  final Map<String, Partner> partners;

  /// The quote the declared value should agree with. A leg declared at a figure the customer
  /// never approved is an insurance argument waiting to happen.
  final Quote? approvedQuote;

  /// D-004. Entirely absent from the mockups — "Confirm Dispatch" was the last wired action in
  /// all 46 screens — and an Indian manufacturer cannot legally ship without one.
  final List<Invoice> invoices;

  /// Proof-of-delivery and commercial-invoice rows, keyed by attachment id, with short-lived
  /// signed URLs for the images among them.
  final Map<String, Attachment> files;
  final Map<String, String> fileUrls;

  /// Whoever ticked a protocol step, keyed by id.
  final Map<String, AppUser> people;

  String get currency => job.currency;

  Money get zero => Money(0, currency);

  // -------------------------------------------------------------- legs

  /// Rail order, so the list reads the way the piece actually travels: wax in, out to the
  /// caster, back, out to the lab, back, out to the customer.
  List<Shipment> get legs => shipments.sorted((a, b) {
        final byLeg = a.leg.index.compareTo(b.leg.index);
        return byLeg != 0 ? byLeg : a.createdAt.compareTo(b.createdAt);
      });

  List<Shipment> legsOf(ShipmentLeg leg) => [for (final s in legs) if (s.leg == leg) s];

  Shipment? shipmentById(String id) => shipments.firstWhereOrNull((s) => s.id == id);

  /// Still to go out, or out and not yet arrived.
  List<Shipment> get open => [for (final s in legs) if (!s.isDelivered) s];

  List<Shipment> get closed => [for (final s in legs) if (s.isDelivered) s];

  /// The newest final-dispatch leg — the one the invoice and the customer care about.
  Shipment? get finalDispatch => legsOf(ShipmentLeg.finalDispatch).lastOrNull;

  /// An unsettled leg of this kind, which is what makes opening a second one worth questioning.
  Shipment? openLegOf(ShipmentLeg leg) =>
      legsOf(leg).firstWhereOrNull((s) => !s.isDelivered);

  bool get hasLegs => shipments.isNotEmpty;

  /// Legs with the protocol still unfinished. The number the list header leads with, because it
  /// is the number standing between the job and its dispatch.
  int get legsAwaitingProtocol => [
        for (final s in legs)
          if (s.status.isDispatchable && !s.isSecurityComplete) s,
      ].length;

  // -------------------------------------------------------------- values

  /// What a leg should be declared at, taken from the approved quote rather than typed from
  /// memory. Null when nothing has been approved — the screen then asks rather than declaring
  /// zero.
  Money? get suggestedDeclaredValue {
    final quote = approvedQuote;
    if (quote == null || quote.grandTotalMinor == 0) return null;
    return quote.grandTotal;
  }

  // -------------------------------------------------------------- invoicing (D-004)

  /// Newest first — `invoices()` already orders by date descending.
  Invoice? get latestInvoice => invoices.firstOrNull;

  Invoice? get issuedInvoice => invoices.firstWhereOrNull((i) => i.isIssued);

  bool get hasIssuedInvoice => issuedInvoice != null;

  /// What to say about the tax invoice above a final dispatch, or null when nothing needs saying.
  ///
  /// This is advice and not a gate: `fn_dispatch_shipment` counts security checks and nothing
  /// else, and inventing a client-side rule the database does not carry is how the two drift.
  /// But shipping an uninvoiced piece out of an Indian workshop is a real exposure, so the
  /// screen says so and the dispatch confirmation repeats it.
  String? get invoiceAdvice {
    if (hasIssuedInvoice) return null;
    final draft = latestInvoice;
    if (draft != null) {
      return 'Invoice ${draft.invoiceNo} is still a draft. Issue it before the piece leaves — '
          'an Indian manufacturer cannot legally ship without a tax invoice.';
    }
    return 'No tax invoice has been raised for this job. An Indian manufacturer cannot legally '
        'ship without one.';
  }

  // -------------------------------------------------------------- rail

  JobStage? get dispatchStage => rail.stageFor(LifecycleStage.dispatch);

  JobStage? get deliveredStage => rail.stageFor(LifecycleStage.delivered);

  /// The rail row a confirmed final delivery closes, or null when the job is not standing at
  /// dispatch. Anything else — a job still at polishing, a rail never seeded — must not be
  /// advanced by a courier's signature, and saying so beats guessing.
  JobStage? get stageToCloseOnDelivery {
    final active = rail.activeStage;
    return active != null && active.stage == LifecycleStage.dispatch ? active : null;
  }

  /// The rail row closing the job closes. `fn_complete_stage` finds no stage after `delivered`,
  /// so it sets `jobs.status = completed` and stamps `closed_at` — which is what finishing a job
  /// order means.
  JobStage? get stageToCloseOnJobClose {
    final active = rail.activeStage;
    return active != null && active.stage == LifecycleStage.delivered ? active : null;
  }

  bool get isJobClosable => stageToCloseOnJobClose != null;

  /// Why confirming a delivery will not move the job, for the confirmation to say out loud.
  String? get advanceNote {
    if (stageToCloseOnDelivery != null) return null;
    final active = rail.activeStage;
    if (active == null) {
      return 'This job has no active stage, so the delivery is recorded without moving anything.';
    }
    return 'The job is at ${active.stage.label}, not Dispatch. The delivery is recorded and the '
        'rail stays where it is.';
  }

  // -------------------------------------------------------------- lookups

  Partner? partnerOf(String? id) => id == null ? null : partners[id];

  String partnerName(String? id, {String fallback = '—'}) => partnerOf(id)?.name ?? fallback;

  AppUser? person(String? id) => id == null ? null : people[id];

  String nameFor(String? id, {String fallback = 'Unrecorded'}) =>
      person(id)?.fullName ?? fallback;

  Attachment? fileOf(String? id) => id == null ? null : files[id];

  String? urlOf(String? id) => id == null ? null : fileUrls[id];

  /// Everything one leg screen needs, resolved off this bundle rather than loaded again.
  ShipmentLegView? viewOf(String shipmentId) {
    final shipment = shipmentById(shipmentId);
    return shipment == null ? null : ShipmentLegView(bundle: this, shipment: shipment);
  }
}

// ================================================================= one leg

/// One leg, with its counterparties and its gates resolved.
///
/// The gate methods are the reason this type exists. [canDispatch] is
/// [Shipment.canDispatch] — the model owns the rule and Postgres enforces it — and everything
/// else here is about which *kind* of leg this is: the corpus's single "Confirm Dispatch" button
/// made no distinction between the wax arriving from Central Hub and the finished ring leaving
/// for the customer, so the inbound legs had no action at all.
final class ShipmentLegView {
  const ShipmentLegView({required this.bundle, required this.shipment});

  final ShippingBundle bundle;
  final Shipment shipment;

  ShipmentLeg get leg => shipment.leg;

  /// Goods coming *in*: we did not dispatch them, so there is no dispatch of ours to confirm.
  /// What there is instead is a receipt, gated on the inspection protocol.
  bool get isInbound => isInboundLeg(leg);

  bool get isFinalDispatch => leg == ShipmentLeg.finalDispatch;

  /// Courier, waybill and value are editable until the leg is dispatched. After that the row is
  /// the record of what was declared.
  bool get isEditable => shipment.status == ShipmentStatus.draft;

  Partner? get fromPartner => bundle.partnerOf(shipment.fromPartner);

  Partner? get toPartner => bundle.partnerOf(shipment.toPartner);

  /// Which partner field this leg's counterparty belongs in: an inbound leg has a sender, an
  /// outbound leg has a recipient.
  Partner? get counterparty => isInbound ? fromPartner : toPartner;

  PartnerKind? get counterpartyKind => counterpartyKindFor(leg);

  Attachment? get commercialInvoice => bundle.fileOf(shipment.commercialInv);

  Attachment? get proofOfDelivery => bundle.fileOf(shipment.podId);

  String? get proofUrl => bundle.urlOf(shipment.podId);

  // -------------------------------------------------------------- dispatch

  /// D-011's sibling in the logistics half of the app. The mockup's gate was cosmetic — its
  /// JavaScript toggled opacity classes and never set `.disabled`, so "Confirm Dispatch" fired
  /// with the tamper-seal protocol incomplete. Bind `onPressed` to this;
  /// `fn_dispatch_shipment` re-checks it and refuses in its own words.
  bool get canDispatch => !isInbound && shipment.canDispatch;

  /// Why dispatch is held shut, in the order the operator should fix it. Never a tooltip: a
  /// long-press hint is undiscoverable on a shop-floor tablet.
  String? get dispatchBlockedReason {
    if (isInbound) return null;
    if (!shipment.status.isDispatchable) return null;
    return shipment.dispatchBlockedReason;
  }

  // -------------------------------------------------------------- receipt

  /// An inbound leg is received once the inspection protocol is done. An outbound leg can only
  /// be received after it has actually left.
  bool get canConfirmDelivery {
    if (shipment.isDelivered) return false;
    return isInbound ? shipment.isSecurityComplete : shipment.status.isInFlight;
  }

  String? get deliveryBlockedReason {
    if (shipment.isDelivered) return null;
    if (isInbound) {
      if (shipment.checks.isEmpty) {
        return 'No inspection protocol has been generated for this leg yet. A receipt with '
            'nothing checked records that the box arrived, not that the contents did.';
      }
      if (!shipment.isSecurityComplete) {
        final open = shipment.checks.length - shipment.passedCheckCount;
        return 'Work through the inspection protocol first: $open step'
            '${open == 1 ? '' : 's'} left.';
      }
      return null;
    }
    if (shipment.status.isDispatchable) {
      return 'This leg has not been dispatched yet, so there is nothing to receive. Complete '
          'the security protocol and dispatch it first.';
    }
    return null;
  }

  /// The word the primary action uses. An inbound leg is *received*; an outbound leg is
  /// *delivered*.
  String get deliveryVerb => isInbound ? 'Record receipt' : 'Confirm delivery';

  // -------------------------------------------------------------- advice

  /// Everything worth saying about this leg before the operator presses anything, worst first.
  List<String> get warnings => <String>[
        if (shipment.whiteGloveMismatch)
          'This leg is going direct to the customer but white-glove prep is switched off. '
              'Turn it on, or route it back to the jeweller.',
        if (shipment.isInternational && (shipment.customsRef?.trim().isEmpty ?? true))
          'An international leg needs a customs reference. Malca-Amit will not accept the '
              'package without one.',
        if (shipment.isInternational && shipment.commercialInv == null)
          'An international leg needs a commercial invoice attached to the package.',
        if (shipment.declaredValueMinor == null)
          'No declared value on this leg. An uninsured high-value package is a loss nobody can '
              'claim against.',
        if (!shipment.insured)
          'Insurance is switched off for this leg. Confirm that is deliberate before it goes.',
        if (isFinalDispatch && bundle.invoiceAdvice != null) bundle.invoiceAdvice!,
        if (shipment.needsProofOfDelivery)
          'Delivered with nothing signed for. Attach the proof of delivery — an undocumented '
              'handover of a high-value piece cannot be defended later.',
      ];

  /// The declared value against what the customer approved. A leg declared well under the quote
  /// is the mistake that costs money on a claim.
  bool get declaredValueUnderQuote {
    final declared = shipment.declaredValue;
    final quoted = bundle.suggestedDeclaredValue;
    if (declared == null || quoted == null) return false;
    if (declared.currency != quoted.currency) return false;
    return declared.minor < quoted.minor;
  }
}

// ================================================================= gateway

final class ShippingGateway {
  const ShippingGateway(
    this._client,
    this._store,
    this._jobs,
    this._customers,
    this._production,
    this._quotes,
  );

  final SupabaseClient _client;
  final AttachmentStore _store;
  final JobRepository _jobs;
  final CustomerRepository _customers;
  final ProductionRepository _production;
  final QuoteRepository _quotes;

  /// The `app_users` columns a name needs. `user_roles` is deliberately not joined: this renders
  /// who ticked what, and a role badge is not part of that.
  static const _peopleSelect = 'id, org_id, principal, full_name, title, initials, email, '
      'phone, avatar_path, is_active, created_at';

  /// Everything `/shipping/<jobId>` renders.
  ///
  /// The reads are sequential on purpose. Running them together with `.wait` would replace a
  /// [DhFailure] — which carries the server's own operator-facing sentence — with a
  /// `ParallelWaitError`, and those sentences are the product.
  Future<ShippingBundle> bundle(String jobId) async {
    final snapshot = await _jobs.getSnapshot(jobId);
    final customerId = snapshot.job.customerId;
    final customer = customerId == null ? null : await _customers.findCustomer(customerId);
    final shipments = await _production.shipments(jobId);
    final approvedQuote = await _quotes.approvedQuote(jobId);
    final invoices = await _quotes.invoices(jobId: jobId);

    final partners = await _partnersFor(<String?>[
      for (final s in shipments) ...[s.fromPartner, s.toPartner],
    ]);

    final files = await _filesFor(<String?>[
      for (final s in shipments) ...[s.podId, s.commercialInv],
    ]);
    final images = [for (final file in files.values) if (file.isImage) file];
    final urls = images.isEmpty ? const <String, String>{} : await _store.signedUrls(images);

    final people = await _peopleFor(<String?>[
      for (final s in shipments)
        for (final check in s.checks) check.checkedBy,
    ]);

    return ShippingBundle(
      job: snapshot.job,
      rail: snapshot.rail,
      customer: customer,
      shipments: shipments,
      partners: partners,
      approvedQuote: approvedQuote,
      invoices: invoices,
      files: files,
      fileUrls: urls,
      people: people,
    );
  }

  // -------------------------------------------------------------- the three columns

  /// `routing`, `from_partner` and `to_partner`, written here rather than in the repository.
  ///
  /// `ProductionRepository.createShipment` accepts all three and `updateShipment` accepts none of
  /// them — it covers courier, waybill, declared value, the flags and the address, which is what
  /// a leg normally has corrected. But the routing decision is exactly the one the mockup put on
  /// the dispatch screen, and it has to be changeable there: an operator who picked "Return to
  /// Jeweller" and then learns the customer is collecting must be able to say so without
  /// deleting the leg and its half-ticked protocol.
  ///
  /// So the three columns are written next to the act that justifies them, the same way
  /// `QcGateway.reopenForInspection` writes `jobs.status`. Nothing else about a leg is written
  /// here — courier, waybill and value still go through the repository, because that is where
  /// the uppercase-forcing and the [Money] handling live.
  ///
  /// Routing is only meaningful on a final dispatch; the column is null on every other leg.
  Future<Shipment> setRouting({
    required String shipmentId,
    required DispatchRouting routing,
  }) async {
    await guard(
      () => _client
          .from('shipments')
          .update(<String, Object?>{
            // Convention 6: the enum crosses as its Postgres value, never `.name`.
            'routing': routing.wire,
            // "Requires white-glove unboxing prep." was stated in the mockup and never carried
            // into the record. Choosing the routing is the moment it becomes true.
            if (routing.needsWhiteGlove) 'white_glove': true,
          })
          .eq('id', shipmentId),
    );
    return _production.shipment(shipmentId);
  }

  /// Attach or detach the partner on the other end. [Opt.clear] detaches; omitting the argument
  /// leaves the column alone.
  Future<Shipment> setCounterparty({
    required String shipmentId,
    Opt<String>? fromPartner,
    Opt<String>? toPartner,
  }) async {
    final values = <String, Object?>{
      if (fromPartner != null) 'from_partner': fromPartner.value,
      if (toPartner != null) 'to_partner': toPartner.value,
    };
    if (values.isEmpty) return _production.shipment(shipmentId);

    await guard(() => _client.from('shipments').update(values).eq('id', shipmentId));
    return _production.shipment(shipmentId);
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
}

// ================================================================= providers

@Riverpod(keepAlive: true)
ShippingGateway shippingGateway(Ref ref) => ShippingGateway(
      ref.watch(supabaseProvider),
      ref.watch(attachmentStoreProvider),
      ref.watch(jobRepositoryProvider),
      ref.watch(customerRepositoryProvider),
      ref.watch(productionRepositoryProvider),
      ref.watch(quoteRepositoryProvider),
    );

/// Every leg of one job, re-read on demand.
///
/// Deliberately not live. A dispatch is irreversible, and a screen that reshuffles its protocol
/// under the operator's thumb mid-decision is worse than one that needs a pull to refresh. Every
/// shipping action invalidates this when it lands.
@riverpod
Future<ShippingBundle> shippingBundle(Ref ref, String jobId) =>
    ref.watch(shippingGatewayProvider).bundle(jobId);
