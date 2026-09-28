/// Every write the dispatch loop makes, in one place, with one busy flag.
///
/// The rule that shapes this file is the dispatch gate. `shipping_dispatch` shipped a
/// tamper-seal protocol whose JavaScript toggled opacity classes and **never set `.disabled`**,
/// so "Confirm Dispatch" fired with the protocol incomplete. The rule now lives in
/// `fn_dispatch_shipment`, which counts the outstanding `shipment_checks` rows and refuses in its
/// own operator-facing words; [Shipment.canDispatch] holds the button shut before it can be
/// pressed. Nothing here re-implements it — a rule implemented three times is a rule that will
/// disagree with itself.
///
/// Three consequences are handled here rather than at a call site:
///
///  * **A protocol is generated, never assumed.** A leg with no checks would dispatch unguarded,
///    because `fn_dispatch_shipment` counts unticked rows and zero rows is zero unticked. So a
///    leg is always seeded ([ShippingProtocols]), and turning on white glove or an international
///    courier *appends the steps that claim implies* — the mockup declared "Requires white-glove
///    unboxing prep" and carried nothing into the record.
///  * **Confirming the final delivery is two writes.** The shipment row records the handover;
///    `fn_complete_stage` moves the rail off Dispatch. If the second fails the first still
///    happened, and the operator has to be told exactly that — not "delivery failed", which
///    would send them back to record a delivery that already exists.
///  * **A dispatch does not walk the rail forward.** Leaving the building is not arriving. The
///    `dispatch` stage closes when the piece is signed for, which is the only moment anyone
///    actually knows it got there.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/repositories/thread_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/shipping/shipping_gateway.dart';
import 'package:dhanaos/features/shipping/shipping_widgets.dart';

part 'shipping_actions.g.dart';

/// Which write is in flight, so the screen can spin the control that was actually pressed rather
/// than greying out everything it owns.
enum ShippingTask {
  openLeg,
  save,
  tick,
  addStep,
  dispatch,
  inTransit,
  deliver,
  attachCustoms,
  closeJob,
}

// ================================================================= protocols

/// The protocols a leg is seeded with.
///
/// Seeded at creation rather than at dispatch, because `fn_dispatch_shipment` refuses a leg with
/// an outstanding check — and a leg with *no* checks has nothing outstanding, so it would sail
/// straight through the gate the whole design exists to close.
abstract final class ShippingProtocols {
  /// The three steps `shipping_dispatch` drew. Kept where the repository put them so the seed and
  /// the gate cannot drift apart.
  static const outbound = ProductionRepository.defaultSecurityProtocol;

  /// Goods arriving. No mockup had a receiving surface at all — the wax "en route from Central
  /// Hub" had nowhere to land — so these are net-new and they are the steps that matter: what
  /// arrives has to be checked against what was sent before anyone signs for it.
  static const inbound = <SecurityCheckSeed>[
    SecurityCheckSeed('Outer packaging intact, no sign of tampering'),
    SecurityCheckSeed('Seal number checked against the courier docket'),
    SecurityCheckSeed('Contents counted and weighed against the job card'),
  ];

  /// 'Requires white-glove unboxing prep.' — stated on the mockup's routing card and carried
  /// nowhere. These are that sentence, as steps that hold the dispatch gate shut until they are
  /// done.
  static const whiteGlove = <SecurityCheckSeed>[
    SecurityCheckSeed('Presentation box, pouch and ribbon fitted'),
    SecurityCheckSeed('Care card and warranty enclosed'),
    SecurityCheckSeed('Piece photographed in its packaging for the customer record'),
    SecurityCheckSeed('Recipient contacted with the delivery window'),
  ];

  /// The mockup's courier list offered Malca-Amit and had a field for neither customs nor a
  /// commercial invoice.
  static const international = <SecurityCheckSeed>[
    SecurityCheckSeed('Commercial invoice in the documents pouch'),
    SecurityCheckSeed('Customs declared value matches the value on this leg'),
    SecurityCheckSeed('HSN 7113 and the certificate number written on the waybill'),
  ];

  /// What a new leg starts with.
  static List<SecurityCheckSeed> forLeg(
    ShipmentLeg leg, {
    bool whiteGlove = false,
    bool international = false,
  }) =>
      <SecurityCheckSeed>[
        ...(isInboundLeg(leg) ? inbound : outbound),
        if (whiteGlove) ...ShippingProtocols.whiteGlove,
        if (international) ...ShippingProtocols.international,
      ];
}

// ================================================================= actions

/// Kept alive because a dispatch or a signature upload must survive the operator flicking to
/// another screen while the round trip is open. An auto-disposed notifier would be torn down
/// under its own `finally`.
@Riverpod(keepAlive: true)
class ShippingActions extends _$ShippingActions {
  /// Null when nothing is in flight.
  @override
  ShippingTask? build() => null;

  bool get isBusy => state != null;

  bool isRunning(ShippingTask task) => state == task;

  ProductionRepository get _production => ref.read(productionRepositoryProvider);

  ShippingGateway get _gateway => ref.read(shippingGatewayProvider);

  // -------------------------------------------------------------- opening a leg

  /// Open one leg of the journey and seed its protocol.
  ///
  /// The mockups modelled one shipment per job while showing four legs on one job. This is the
  /// act that fixes that: a leg is opened for the movement about to happen, not for the job as a
  /// whole.
  Future<Shipment> openLeg({
    required String jobId,
    required ShipmentLeg leg,
    DispatchRouting? routing,
    Money? declaredValue,
    String? counterpartyId,
    bool isInternational = false,
    ShipAddress? address,
  }) async {
    state = ShippingTask.openLeg;
    try {
      final inbound = isInboundLeg(leg);
      final whiteGlove = routing?.needsWhiteGlove ?? false;
      final created = await _production.createShipment(
        jobId: jobId,
        leg: leg,
        routing: leg == ShipmentLeg.finalDispatch ? routing : null,
        // Inbound goods were sent to us; outbound goods are sent by us.
        fromPartner: inbound ? counterpartyId : null,
        toPartner: inbound ? null : counterpartyId,
        toAddress: address?.toMap() ?? const <String, dynamic>{},
        declaredValue: declaredValue,
        isInternational: isInternational,
        whiteGlove: whiteGlove,
        securityChecks: ShippingProtocols.forLeg(
          leg,
          whiteGlove: whiteGlove,
          international: isInternational,
        ),
      );

      await _note(
        jobId: jobId,
        stage: stageForLeg(leg),
        body: '${leg.label} leg opened with a '
            '${created.checks.length}-step protocol.',
      );
      return created;
    } finally {
      state = null;
      _after(jobId);
    }
  }

  // -------------------------------------------------------------- editing a leg

  /// Courier, waybill, declared value and the flags. Omitted arguments are left untouched.
  ///
  /// Turning the international flag on appends the customs steps, because an international leg
  /// with the domestic protocol would pass the gate having checked none of the things that
  /// actually stop it at a border.
  Future<Shipment> saveDetails({
    required String jobId,
    required Shipment shipment,
    Courier? courier,
    String? courierOther,
    String? waybill,
    Money? declaredValue,
    bool? insured,
    bool? isInternational,
    String? customsRef,
    bool? signatureReq,
    bool? whiteGlove,
    ShipAddress? address,
  }) async {
    state = ShippingTask.save;
    try {
      // An international courier forces the flag: the mockup let Malca-Amit be picked with the
      // domestic paperwork, which is a package that will not clear.
      final goesInternational =
          isInternational ?? (courier?.isInternational ?? shipment.isInternational);

      var updated = await _production.updateShipment(
        shipmentId: shipment.id,
        courier: courier,
        courierOther: courierOther,
        waybill: waybill,
        declaredValue: declaredValue,
        insured: insured,
        isInternational: goesInternational == shipment.isInternational ? null : goesInternational,
        customsRef: customsRef,
        signatureReq: signatureReq,
        whiteGlove: whiteGlove,
        toAddress: address?.toMap(),
      );

      if (goesInternational && !shipment.isInternational) {
        updated = await _appendSteps(updated, ShippingProtocols.international);
      }
      if ((whiteGlove ?? false) && !shipment.whiteGlove) {
        updated = await _appendSteps(updated, ShippingProtocols.whiteGlove);
      }
      return updated;
    } finally {
      state = null;
      _after(jobId);
    }
  }

  /// Change where a final dispatch is going.
  ///
  /// The mockup's radio cards put their checked utilities on the wrong element, so selection never
  /// showed and nothing was ever stored. This writes it, and a direct-to-customer routing brings
  /// the white-glove steps with it.
  Future<Shipment> setRouting({
    required String jobId,
    required Shipment shipment,
    required DispatchRouting routing,
    ShipAddress? address,
  }) async {
    state = ShippingTask.save;
    try {
      var updated = await _gateway.setRouting(shipmentId: shipment.id, routing: routing);
      if (address != null && !address.isEmpty) {
        updated = await _production.updateShipment(
          shipmentId: shipment.id,
          toAddress: address.toMap(),
        );
      }
      if (routing.needsWhiteGlove) {
        updated = await _appendSteps(updated, ShippingProtocols.whiteGlove);
      }
      return updated;
    } finally {
      state = null;
      _after(jobId);
    }
  }

  /// Attach or detach the partner on the other end of a leg.
  Future<Shipment> setCounterparty({
    required String jobId,
    required Shipment shipment,
    required String? partnerId,
  }) async {
    state = ShippingTask.save;
    try {
      final slot = partnerId == null ? const Opt<String>.clear() : Opt<String>(partnerId);
      return await _gateway.setCounterparty(
        shipmentId: shipment.id,
        fromPartner: isInboundLeg(shipment.leg) ? slot : null,
        toPartner: isInboundLeg(shipment.leg) ? null : slot,
      );
    } finally {
      state = null;
      _after(jobId);
    }
  }

  // -------------------------------------------------------------- the protocol

  /// Tick or untick one step. Unticking deliberately leaves the serial alone: a seal already
  /// applied to a box keeps its number.
  Future<Shipment> tickCheck({
    required String jobId,
    required Shipment shipment,
    required ShipmentCheck check,
    required bool passed,
  }) async {
    state = ShippingTask.tick;
    try {
      return await _production.setShipmentCheck(
        shipmentId: shipment.id,
        checkId: check.id,
        passed: passed,
      );
    } finally {
      state = null;
      _after(jobId);
    }
  }

  /// Record the seal or docket number on a step. A ticked seal with no serial cannot be verified
  /// later ([ShipmentCheck.needsReference]).
  Future<Shipment> setReference({
    required String jobId,
    required Shipment shipment,
    required ShipmentCheck check,
    required String reference,
  }) async {
    state = ShippingTask.tick;
    try {
      return await _production.setShipmentCheck(
        shipmentId: shipment.id,
        checkId: check.id,
        passed: check.passed,
        reference: reference,
      );
    } finally {
      state = null;
      _after(jobId);
    }
  }

  /// Add a step the standard protocol does not cover.
  Future<Shipment> addStep({
    required String jobId,
    required Shipment shipment,
    required String label,
    String? reference,
  }) async {
    state = ShippingTask.addStep;
    try {
      return await _production.addShipmentCheck(
        shipmentId: shipment.id,
        label: label,
        reference: reference,
      );
    } finally {
      state = null;
      _after(jobId);
    }
  }

  // -------------------------------------------------------------- movement

  /// Send it. `fn_dispatch_shipment` is the gate; this only asks.
  ///
  /// Nothing is pre-checked here. The button is held shut by [ShipmentLegView.canDispatch] and
  /// the data is held shut by Postgres, whose refusal — "Complete the security protocol first —
  /// 2 check(s) outstanding" — reaches the operator unaltered.
  Future<Shipment> dispatchLeg({
    required String jobId,
    required Shipment shipment,
  }) async {
    state = ShippingTask.dispatch;
    try {
      final dispatched = await _production.dispatchShipment(shipment.id);
      final waybill = dispatched.waybill;
      await _note(
        jobId: jobId,
        stage: stageForLeg(shipment.leg),
        // A dispatch is a customer-visible event: they are waiting for this package.
        isInternal: shipment.leg != ShipmentLeg.finalDispatch,
        body: [
          '${shipment.leg.label} dispatched via ${dispatched.courierLabel}.',
          if (waybill != null && waybill.trim().isNotEmpty) 'Waybill $waybill.',
          if (dispatched.declaredValue != null)
            'Declared at ${dispatched.declaredValue!.format()}'
                '${dispatched.insured ? ' and insured' : ', uninsured'}.',
          'Security protocol ${dispatched.checkProgressLabel} complete.',
        ].join(' '),
      );
      return dispatched;
    } finally {
      state = null;
      _after(jobId);
    }
  }

  /// The courier has scanned it. Not a gate, just the truth about where the package is.
  Future<Shipment> markInTransit({
    required String jobId,
    required Shipment shipment,
  }) async {
    state = ShippingTask.inTransit;
    try {
      return await _production.markInTransit(shipment.id);
    } finally {
      state = null;
      _after(jobId);
    }
  }

  /// Record the handover, and close the Dispatch stage when this was the leg that mattered.
  ///
  /// "Confirm Dispatch" was the last wired action in all 46 mockups: nothing in the corpus knew
  /// what happened after the van left. This is that missing act — and because it is two writes,
  /// a failure on the second says so precisely rather than inviting the operator to record a
  /// delivery that is already on the record.
  Future<Shipment> confirmDelivery({
    required String jobId,
    required ShipmentLegView view,
    required DateTime deliveredAt,
    String? receivedBy,
    FileUpload? proof,
    bool advanceRail = true,
  }) async {
    state = ShippingTask.deliver;
    final shipment = view.shipment;
    try {
      final delivered = await _production.markDelivered(
        shipmentId: shipment.id,
        jobId: jobId,
        deliveredAt: deliveredAt,
        receivedBy: receivedBy,
        proofOfDelivery: proof,
      );

      final closing = advanceRail && view.isFinalDispatch
          ? view.bundle.stageToCloseOnDelivery
          : null;
      if (closing != null) {
        try {
          await ref.read(jobRepositoryProvider).completeStage(
                jobId: jobId,
                stage: closing.stage,
                notes: 'Delivered${receivedBy == null ? '' : ' — received by $receivedBy'}.',
              );
        } on DhFailure catch (failure, stack) {
          Error.throwWithStackTrace(
            RuleViolation(
              message: 'The delivery is on the record, but the job did not move off Dispatch: '
                  '${failure.message}',
              detail: failure.detail,
              code: failure.code,
            ),
            stack,
          );
        }
      }

      await _note(
        jobId: jobId,
        stage: stageForLeg(shipment.leg),
        // The customer is the other end of a final dispatch, so the handover is theirs to see.
        isInternal: !view.isFinalDispatch,
        body: [
          view.isInbound
              ? '${shipment.leg.label} received.'
              : '${shipment.leg.label} delivered.',
          if (receivedBy != null && receivedBy.trim().isNotEmpty)
            'Signed for by ${receivedBy.trim()}.',
          if (delivered.podId != null) 'Proof of delivery attached.',
        ].join(' '),
      );
      return delivered;
    } finally {
      state = null;
      _after(jobId);
    }
  }

  /// The commercial invoice that travels in the documents pouch on an international leg.
  ///
  /// Distinct from the GST tax invoice: that one is a legal document raised against the customer
  /// (D-004), this one is the paper a customs officer reads. The mockup had neither.
  Future<Shipment> attachCustomsInvoice({
    required String jobId,
    required Shipment shipment,
    required FileUpload invoice,
  }) async {
    state = ShippingTask.attachCustoms;
    try {
      return await _production.attachCommercialInvoice(
        shipmentId: shipment.id,
        jobId: jobId,
        invoice: invoice,
      );
    } finally {
      state = null;
      _after(jobId);
    }
  }

  // -------------------------------------------------------------- closing the job

  /// Close the job order.
  ///
  /// `fn_complete_stage` finds no stage after `delivered`, so it sets `jobs.status = completed`
  /// and stamps `closed_at`. Every gate in the mockups was one-way and none of them was this
  /// one: the corpus had no act that finished a job at all.
  Future<void> closeJob({
    required String jobId,
    required JobStage deliveredStage,
  }) async {
    state = ShippingTask.closeJob;
    try {
      await ref.read(jobRepositoryProvider).completeStage(
            jobId: jobId,
            stage: deliveredStage.stage,
            notes: 'Delivery confirmed and the order closed.',
          );
      await _note(
        jobId: jobId,
        stage: LifecycleStage.delivered,
        isInternal: false,
        body: 'Order closed. The piece is with the customer and the job is complete.',
      );
    } finally {
      state = null;
      _after(jobId);
    }
  }

  // -------------------------------------------------------------- plumbing

  /// Add any of [seeds] whose label is not already on the leg.
  ///
  /// Idempotent on purpose: an operator who toggles white glove off and on again must not end up
  /// with the four steps twice, and a protocol with duplicate rows would need every duplicate
  /// ticked before the gate opened.
  Future<Shipment> _appendSteps(Shipment shipment, List<SecurityCheckSeed> seeds) async {
    final existing = <String>{for (final check in shipment.checks) check.label.toLowerCase()};
    var current = shipment;
    for (final seed in seeds) {
      if (existing.contains(seed.label.toLowerCase())) continue;
      current = await _production.addShipmentCheck(
        shipmentId: shipment.id,
        label: seed.label,
        reference: seed.reference,
      );
    }
    return current;
  }

  /// A movement writes to the digital thread as well as to the row, because `job_detail`'s core
  /// mechanic is one chronological stream and a package that moved with nothing in the feed is
  /// invisible to everyone not looking at this screen.
  ///
  /// A failure here is swallowed deliberately: the movement itself succeeded, and reporting "the
  /// dispatch failed" because a note did not post would be a lie that sends the operator back to
  /// dispatch a package already in a van.
  Future<void> _note({
    required String jobId,
    required LifecycleStage stage,
    required String body,
    bool isInternal = true,
  }) async {
    try {
      await ref.read(threadRepositoryProvider).postMessage(
            jobId: jobId,
            body: body,
            stage: stage,
            isInternal: isInternal,
          );
    } on DhFailure catch (_) {
      // Nothing useful to do here. The row is written; the feed will catch up on the next post.
    }
  }

  /// Re-read after every write, including a failed one: `saveDetails` and `confirmDelivery` both
  /// have a first write that can land before a second fails, so the screen must never keep
  /// showing what it thought was true.
  void _after(String jobId) {
    ref.invalidate(shippingBundleProvider(jobId));
    ref.invalidate(jobShipmentsProvider(jobId));
    ref.invalidate(jobSnapshotProvider(jobId));
  }
}
