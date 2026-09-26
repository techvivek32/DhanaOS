/// One leg: where it is going, who is carrying it, what it is worth, and the protocol that has to
/// be finished before it can leave.
///
/// A rebuild of `shipping_dispatch`, which shipped three defects this screen exists to correct:
///
///  * **The security gate was cosmetic.** Its JavaScript toggled opacity classes and never set
///    `.disabled`, so "Confirm Dispatch" fired with the tamper-seal protocol incomplete. Here
///    `onPressed` is null until [ShipmentLegView.canDispatch] is true, and
///    `fn_dispatch_shipment` refuses the write independently — the button is the courtesy, the
///    function is the rule.
///  * **The routing cards never showed a selection.** The radio inputs carried their `checked:`
///    utilities on the wrong element, so tapping a card changed nothing visible and the choice
///    was never stored. [SelectableTile] has a real selected state, and the choice is written to
///    `shipments.routing`.
///  * **Two branches were declared and never built.** The courier list offered Malca-Amit with no
///    customs field and no commercial invoice; the routing card promised "Requires white-glove
///    unboxing prep" with nothing behind it. Both now reveal real fields, and both append the
///    protocol steps they imply — so a claim made on this screen is a claim the dispatch gate
///    enforces.
///
/// Tap-selections are written immediately and the screen reads them back from the row rather than
/// from a local mirror: on a surface that decides what an insurer was told, the screen must never
/// show a value the database does not hold. Text and money fields are the exception — they save
/// when they lose focus, and an "Unsaved" chip says so until they do.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/shipping/delivery_confirm.dart';
import 'package:dhanaos/features/shipping/shipping_actions.dart';
import 'package:dhanaos/features/shipping/shipping_gateway.dart';
import 'package:dhanaos/features/shipping/shipping_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class ShipmentScreen extends ConsumerWidget {
  const ShipmentScreen({super.key, required this.jobId, required this.shipmentId});

  final String jobId;

  /// `shipments.id`. A leg is addressed by the movement, not by the job, so a link in a message
  /// opens the exact package under discussion.
  final String shipmentId;

  static Future<void> push(
    BuildContext context, {
    required String jobId,
    required String shipmentId,
  }) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ShipmentScreen(jobId: jobId, shipmentId: shipmentId),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(shippingBundleProvider(jobId));

    return async.when(
      loading: () => const _Frame(
        child: Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoadingSkeleton(height: 72),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
            ],
          ),
        ),
      ),
      error: (error, _) => _Frame(
        child: ErrorState(
          title: 'This leg did not open',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read the shipment. Check the connection and try again.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(shippingBundleProvider(jobId)),
        ),
      ),
      data: (bundle) {
        final view = bundle.viewOf(shipmentId);
        if (view == null) {
          return _Frame(
            child: ErrorState(
              icon: Icons.no_transfer_outlined,
              title: 'That leg is no longer on this job',
              message: 'It was removed, or it belongs to a different job order. Go back to the '
                  'shipping list to see what is open.',
              onSecondary: () => Navigator.of(context).maybePop(),
              secondaryLabel: 'Back to the legs',
            ),
          );
        }
        return _LegEditor(key: ValueKey(shipmentId), view: view);
      },
    );
  }
}

/// The scaffold the loading and error states borrow, so the app bar does not appear late.
final class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Shipment leg')),
        body: child,
      );
}

// ================================================================= the editor

final class _LegEditor extends ConsumerStatefulWidget {
  const _LegEditor({super.key, required this.view});

  final ShipmentLegView view;

  @override
  ConsumerState<_LegEditor> createState() => _LegEditorState();
}

class _LegEditorState extends ConsumerState<_LegEditor> {
  late final TextEditingController _waybill =
      TextEditingController(text: widget.view.shipment.waybill ?? '');
  late final TextEditingController _courierOther =
      TextEditingController(text: widget.view.shipment.courierOther ?? '');
  late final TextEditingController _customsRef =
      TextEditingController(text: widget.view.shipment.customsRef ?? '');

  late Money _declared = widget.view.shipment.declaredValue ??
      Money(0, widget.view.shipment.currency);

  /// True while a field in the details block holds focus. Server values are not adopted then —
  /// having a half-typed waybill rewritten under the caret is worse than being one round trip
  /// stale.
  bool _editing = false;

  Shipment get _shipment => widget.view.shipment;

  String get _jobId => widget.view.bundle.job.id;

  @override
  void initState() {
    super.initState();
    // The "Unsaved" chip and the footer's wording both read the dirty state, so a keystroke has
    // to reach the frame. Nothing is sent to the server here — only on blur.
    _waybill.addListener(_onTyped);
    _courierOther.addListener(_onTyped);
    _customsRef.addListener(_onTyped);
  }

  void _onTyped() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(_LegEditor old) {
    super.didUpdateWidget(old);
    if (_editing || widget.view.shipment == old.view.shipment) return;
    _adopt(_waybill, _shipment.waybill);
    _adopt(_courierOther, _shipment.courierOther);
    _adopt(_customsRef, _shipment.customsRef);
    final stored = _shipment.declaredValue ?? Money(0, _shipment.currency);
    if (stored != _declared) _declared = stored;
  }

  static void _adopt(TextEditingController controller, String? stored) {
    final text = stored ?? '';
    if (controller.text != text) controller.text = text;
  }

  @override
  void dispose() {
    _waybill
      ..removeListener(_onTyped)
      ..dispose();
    _courierOther
      ..removeListener(_onTyped)
      ..dispose();
    _customsRef
      ..removeListener(_onTyped)
      ..dispose();
    super.dispose();
  }

  // -------------------------------------------------------------- dirty state

  String? _typed(TextEditingController controller) {
    final text = controller.text.trim();
    return text.isEmpty ? null : text;
  }

  bool get _hasUnsaved =>
      _typed(_waybill) != _shipment.waybill?.trim() ||
      _typed(_courierOther) != _shipment.courierOther?.trim() ||
      _typed(_customsRef) != _shipment.customsRef?.trim() ||
      _declared != (_shipment.declaredValue ?? Money(0, _shipment.currency));

  // -------------------------------------------------------------- writes

  /// One patch for everything on this screen.
  ///
  /// The typed fields are always included when they differ from the row, so a tap-selection can
  /// never discard a waybill the operator typed and did not blur out of. `updateShipment` reads
  /// an empty string as "clear this column", which is exactly what an emptied field means.
  Future<void> _save({
    Courier? courier,
    bool? insured,
    bool? signatureReq,
    bool? isInternational,
    bool? whiteGlove,
    ShipAddress? address,
  }) async {
    final shipment = _shipment;
    final declaredChanged =
        _declared != (shipment.declaredValue ?? Money(0, shipment.currency));

    try {
      await ref.read(shippingActionsProvider.notifier).saveDetails(
            jobId: _jobId,
            shipment: shipment,
            courier: courier,
            courierOther: _typed(_courierOther) == shipment.courierOther?.trim()
                ? null
                : _courierOther.text,
            waybill:
                _typed(_waybill) == shipment.waybill?.trim() ? null : _waybill.text,
            customsRef: _typed(_customsRef) == shipment.customsRef?.trim()
                ? null
                : _customsRef.text,
            declaredValue: declaredChanged ? _declared : null,
            insured: insured,
            signatureReq: signatureReq,
            isInternational: isInternational,
            whiteGlove: whiteGlove,
            address: address,
          );
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _setRouting(DispatchRouting routing) async {
    final customer = widget.view.bundle.customer;
    // "Return to Jeweller" means the retailer we manufacture for, and their address is already
    // on file. Snapshot it onto the leg rather than joining it later: the address a package was
    // sent to must not change because the retailer moved.
    final prefill = routing == DispatchRouting.jeweler && customer != null
        ? ShipAddress.fromCustomer(customer)
        : null;
    try {
      await ref.read(shippingActionsProvider.notifier).setRouting(
            jobId: _jobId,
            shipment: _shipment,
            routing: routing,
            address: _shipment.toAddress.isEmpty ? prefill : null,
          );
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _chooseCounterparty() async {
    final kind = widget.view.counterpartyKind;
    if (kind == null) return;
    final choice = await pickPartner(
      context,
      kind: kind,
      selectedId: widget.view.counterparty?.id,
    );
    if (choice == null || !mounted) return;
    try {
      await ref.read(shippingActionsProvider.notifier).setCounterparty(
            jobId: _jobId,
            shipment: _shipment,
            partnerId: switch (choice) {
              PartnerPicked(:final partner) => partner.id,
              PartnerCleared() => null,
            },
          );
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _tick(ShipmentCheck check, {required bool passed}) async {
    try {
      await ref.read(shippingActionsProvider.notifier).tickCheck(
            jobId: _jobId,
            shipment: _shipment,
            check: check,
            passed: passed,
          );
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _reference(ShipmentCheck check, String reference) async {
    try {
      await ref.read(shippingActionsProvider.notifier).setReference(
            jobId: _jobId,
            shipment: _shipment,
            check: check,
            reference: reference,
          );
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _addStep() async {
    final label = await promptForText(
      context,
      title: 'Add a protocol step',
      message: 'It joins the end of the protocol, and this leg cannot be dispatched until it is '
          'ticked.',
      fieldLabel: 'What has to be done',
      submitLabel: 'Add the step',
      hint: 'Customs seal applied to the outer carton',
      minLines: 2,
    );
    if (label == null || !mounted) return;
    try {
      await ref.read(shippingActionsProvider.notifier).addStep(
            jobId: _jobId,
            shipment: _shipment,
            label: label,
          );
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _attachCommercialInvoice() async {
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: 'Commercial invoice for customs',
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
      );
    } on Exception catch (error) {
      if (!mounted) return;
      showFailure(
        context,
        StorageFailure(
          message: 'The file browser could not be opened. Try the camera instead, or check that '
              'DhanaOS has file permission.',
          detail: error.toString(),
        ),
      );
      return;
    }
    final chosen = picked;
    if (chosen == null || !mounted) return;

    // Android hands back a content:// uri for some providers, which has no local path and
    // nothing here can stream. Saying so beats staging a file that cannot upload.
    final path = chosen.path;
    if (path == null) {
      showFailure(
        context,
        const StorageFailure(
          message: 'That file has no local copy this build can stream. Save it to the device '
              'first, then attach it.',
          code: 'no_local_path',
        ),
      );
      return;
    }

    try {
      await ref.read(shippingActionsProvider.notifier).attachCustomsInvoice(
            jobId: _jobId,
            shipment: _shipment,
            invoice: FileUpload.file(File(path), filename: chosen.name),
          );
      if (!mounted) return;
      showDone(context, 'Commercial invoice attached to this leg.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _photographPaperwork() async {
    XFile? shot;
    try {
      shot = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 88);
    } on Exception catch (error) {
      if (!mounted) return;
      showFailure(
        context,
        StorageFailure(
          message: 'The camera could not be opened. Check that DhanaOS has camera permission.',
          detail: error.toString(),
        ),
      );
      return;
    }
    final file = shot;
    if (file == null || !mounted) return;
    try {
      await ref.read(shippingActionsProvider.notifier).attachCustomsInvoice(
            jobId: _jobId,
            shipment: _shipment,
            invoice: FileUpload.file(File(file.path), filename: file.name),
          );
      if (!mounted) return;
      showDone(context, 'Commercial invoice attached to this leg.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  // -------------------------------------------------------------- dispatch

  Future<void> _dispatch() async {
    // Nothing typed may be left behind: the courier reads the waybill off the row, not off the
    // screen.
    if (_hasUnsaved) await _save();
    if (!mounted) return;

    final shipment = _shipment;
    final invoiceNote = widget.view.isFinalDispatch ? widget.view.bundle.invoiceAdvice : null;
    final confirmed = await confirmAction(
      context,
      title: 'Dispatch this leg?',
      message: [
        '${shipment.leg.label} goes out with ${shipment.courierLabel}'
            '${shipment.waybill == null ? '' : ' on waybill ${shipment.waybill}'}.',
        if (shipment.declaredValue != null)
          'Declared at ${shipment.declaredValue!.format()}'
              '${shipment.insured ? ' and insured.' : ' with insurance switched OFF.'}',
        'The protocol is ${shipment.checkProgressLabel} complete.',
        if (invoiceNote != null) invoiceNote,
        'Dispatch is recorded on the audit trail and cannot be undone.',
      ].join('\n\n'),
      confirmLabel: 'Dispatch it',
      cancelLabel: 'Not yet',
    );
    if (!confirmed || !mounted) return;

    try {
      await ref
          .read(shippingActionsProvider.notifier)
          .dispatchLeg(jobId: _jobId, shipment: shipment);
      if (!mounted) return;
      showDone(context, '${shipment.leg.label} dispatched.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _markInTransit() async {
    try {
      await ref
          .read(shippingActionsProvider.notifier)
          .markInTransit(jobId: _jobId, shipment: _shipment);
      if (!mounted) return;
      showDone(context, 'Marked in transit.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final shipment = view.shipment;
    final task = ref.watch(shippingActionsProvider);
    final busy = task != null;
    final permissions = ref.watch(permissionsProvider);
    final canPrepare = permissions.canDispatch || permissions.canEditJob;
    final editable = view.isEditable && canPrepare && !busy;

    return Scaffold(
      appBar: AppBar(
        title: Text(shipment.leg.label),
        actions: [
          if (_hasUnsaved)
            const Padding(
              padding: EdgeInsets.only(right: Spacing.sm),
              child: Center(
                child: StatusChip(
                  label: 'Unsaved',
                  dense: true,
                  tone: ChipTone.warning,
                  tooltip: 'Move off the field to store what you typed.',
                ),
              ),
            ),
          IconButton(
            onPressed: busy ? null : () => ref.invalidate(shippingBundleProvider(_jobId)),
            tooltip: 'Re-read this leg',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(shippingBundleProvider(_jobId).future),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xl),
          children: [
            _header(view),
            for (final warning in view.warnings) ...[
              const SizedBox(height: Spacing.sm + Spacing.xs),
              AdviceNote(tone: AdviceTone.risk, text: warning),
            ],
            if (view.isFinalDispatch) ...[
              const SizedBox(height: Spacing.md),
              _routingCard(view, enabled: editable),
              const SizedBox(height: Spacing.md),
              AddressCard(
                value: ShipAddress.fromMap(shipment.toAddress),
                enabled: editable,
                title: 'Deliver to',
                subtitle: shipment.routing == null
                    ? 'Choose a routing first — it decides whose address this is.'
                    : shipment.routing == DispatchRouting.jeweler
                        ? 'The retailer this job was ordered by.'
                        : 'The retailer\'s own customer. This address is not on any other '
                            'record, so it has to be typed here.',
                prefillLabel: 'Use the customer on file',
                onPrefill: editable && widget.view.bundle.customer != null
                    ? () => unawaited(
                          _save(
                            address:
                                ShipAddress.fromCustomer(widget.view.bundle.customer!),
                          ),
                        )
                    : null,
                onChanged: (next) => unawaited(_save(address: next)),
              ),
            ] else if (view.counterpartyKind != null) ...[
              const SizedBox(height: Spacing.md),
              _counterpartyCard(view, enabled: editable),
            ],
            const SizedBox(height: Spacing.md),
            _courierCard(view, enabled: editable),
            const SizedBox(height: Spacing.md),
            _valueCard(view, enabled: editable),
            if (shipment.isInternational) ...[
              const SizedBox(height: Spacing.md),
              _customsCard(view, enabled: editable),
            ],
            const SizedBox(height: Spacing.md),
            SecurityProtocolCard(
              shipment: shipment,
              enabled: editable,
              onToggle: (ShipmentCheck check, {required bool passed}) =>
                  unawaited(_tick(check, passed: passed)),
              onReference: (ShipmentCheck check, String reference) =>
                  unawaited(_reference(check, reference)),
              onAddStep: editable ? () => unawaited(_addStep()) : null,
            ),
            if (shipment.isDelivered) ...[
              const SizedBox(height: Spacing.md),
              _deliveryRecord(view),
            ],
          ],
        ),
      ),
      bottomNavigationBar: _footer(view, permissions: permissions, task: task),
    );
  }

  // -------------------------------------------------------------- sections

  Widget _header(ShipmentLegView view) {
    final shipment = view.shipment;
    final job = view.bundle.job;

    return DhCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                shipmentLegIcon(shipment.leg),
                size: 22,
                color: context.scheme.onSurfaceVariant,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(child: Text(shipment.leg.label, style: context.text.headlineSmall)),
              ShipmentStatusChip(shipment.status, dense: true),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              StatusChip.code(job.displayCode, dense: true),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  job.displayTitle,
                  style: context.text.bodyMedium
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          DataPairGrid(
            children: [
              DataPair.custom(
                label: 'Protocol',
                child: StatusChip(
                  label: shipment.checkProgressLabel,
                  mono: true,
                  dense: true,
                  tone: shipment.isSecurityComplete ? ChipTone.success : ChipTone.warning,
                ),
              ),
              if (shipment.dispatchedAt != null)
                DataPair.timestamp(label: 'Dispatched', utc: shipment.dispatchedAt!),
              if (shipment.deliveredAt != null)
                DataPair.timestamp(
                  label: view.isInbound ? 'Received' : 'Delivered',
                  utc: shipment.deliveredAt!,
                ),
              if (shipment.transitTime != null && !shipment.isDelivered)
                DataPair.mono(
                  label: 'In transit',
                  value: shortSpan(shipment.transitTime!),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The routing decision, with a selection that is actually visible.
  Widget _routingCard(ShipmentLegView view, {required bool enabled}) {
    final shipment = view.shipment;

    return DhSectionCard(
      title: 'Routing',
      subtitle: 'Where the finished piece goes. It decides the address, the packaging and the '
          'protocol.',
      leading: const Icon(Icons.alt_route_rounded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableTileGroup<DispatchRouting>(
            values: DispatchRouting.values,
            selected: shipment.routing,
            labelOf: (routing) => routing.label,
            blurbOf: (routing) => routing.blurb,
            iconOf: (routing) => switch (routing) {
              DispatchRouting.jeweler => Icons.store_mall_directory_outlined,
              DispatchRouting.customer => Icons.card_giftcard_rounded,
            },
            enabledOf: (_) => enabled,
            disabledReasonOf: (_) => enabled
                ? null
                : 'The routing is fixed once the leg is dispatched, and only Logistics or an '
                    'Admin may change it before then.',
            onChanged: (routing) => unawaited(_setRouting(routing)),
          ),
          if (shipment.routing?.needsWhiteGlove ?? false) ...[
            const SizedBox(height: Spacing.md),
            const AdviceNote(
              tone: AdviceTone.consequence,
              text: 'Direct to customer adds the white-glove steps to the protocol: '
                  'presentation packaging, care card, an unboxing photograph and a call to the '
                  'recipient. Dispatch stays shut until all four are ticked.',
            ),
          ],
          const SizedBox(height: Spacing.md),
          ToggleRow(
            title: 'White-glove preparation',
            icon: Icons.redeem_outlined,
            value: shipment.whiteGlove,
            blurb: 'Presentation packaging and an unboxing the customer will photograph.',
            lockedReason: (shipment.routing?.needsWhiteGlove ?? false)
                ? 'Forced on by a direct-to-customer routing.'
                : null,
            enabled: enabled,
            onChanged: (value) => unawaited(_save(whiteGlove: value)),
          ),
        ],
      ),
    );
  }

  /// Who is on the other end of an internal leg — the caster, the lab, the hub.
  Widget _counterpartyCard(ShipmentLegView view, {required bool enabled}) {
    final partner = view.counterparty;
    final kind = view.counterpartyKind!;

    return DhSectionCard(
      title: view.isInbound ? 'Coming from' : 'Going to',
      subtitle: 'Scoped to ${kind.label.toLowerCase()} partners, so a courier cannot be '
          'recorded as the workshop on the other end.',
      leading: const Icon(Icons.handshake_outlined),
      child: SelectableTile(
        title: partner?.name ?? 'Choose a ${kind.label.toLowerCase()} partner',
        blurb: partner == null
            ? 'The leg can be dispatched without one, but nobody will know who has the piece.'
            : [
                partner.kind.label,
                if (partner.contactName?.trim().isNotEmpty ?? false)
                  partner.contactName!.trim(),
                if (partner.phone?.trim().isNotEmpty ?? false) partner.phone!.trim(),
              ].join(' · '),
        icon: Icons.storefront_outlined,
        selected: partner != null,
        enabled: enabled,
        disabledReason: 'The counterparty is fixed once the leg is dispatched.',
        onTap: () => unawaited(_chooseCounterparty()),
      ),
    );
  }

  Widget _courierCard(ShipmentLegView view, {required bool enabled}) {
    final shipment = view.shipment;

    return DhSectionCard(
      title: 'Courier',
      subtitle: 'A waybill gets read out over the phone, so it is stored the way it is spoken.',
      leading: const Icon(Icons.local_shipping_outlined),
      child: Focus(
        onFocusChange: (hasFocus) {
          _editing = hasFocus;
          if (!hasFocus && _hasUnsaved) unawaited(_save());
          setState(() {});
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableTileGroup<Courier>(
              values: Courier.values,
              selected: shipment.courier,
              dense: true,
              labelOf: (courier) => courier.label,
              iconOf: (courier) => switch (courier) {
                Courier.brinks => Icons.security_rounded,
                Courier.fedex => Icons.flight_takeoff_rounded,
                Courier.malcaAmit => Icons.public_rounded,
                Courier.bluedart => Icons.local_shipping_outlined,
                Courier.other => Icons.more_horiz_rounded,
              },
              badgeOf: (courier) => courier.note.isEmpty
                  ? null
                  : StatusChip(
                      label: courier.note,
                      dense: true,
                      tone: courier.isInternational ? ChipTone.accent : ChipTone.neutral,
                    ),
              enabledOf: (_) => enabled,
              disabledReasonOf: (_) =>
                  enabled ? null : 'The courier is fixed once the leg is dispatched.',
              onChanged: (courier) => unawaited(_save(courier: courier)),
            ),
            if (shipment.courier == Courier.other) ...[
              const SizedBox(height: Spacing.md),
              LabelledField(
                label: 'Courier name',
                controller: _courierOther,
                enabled: enabled,
                hint: 'Who is actually carrying it',
                helperText: 'Printed on the job card and quoted to the insurer.',
              ),
            ],
            const SizedBox(height: Spacing.md),
            LabelledField(
              label: 'Waybill / AWB',
              controller: _waybill,
              enabled: enabled,
              mono: true,
              uppercase: true,
              hint: '9876543210',
              helperText: 'Leave it blank until the courier issues one.',
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => unawaited(_save()),
            ),
            const SizedBox(height: Spacing.md),
            ToggleRow(
              title: 'Signature required on delivery',
              icon: Icons.draw_outlined,
              value: shipment.signatureReq,
              blurb: 'A high-value piece left at a door is an undocumented handover.',
              enabled: enabled,
              onChanged: (value) => unawaited(_save(signatureReq: value)),
            ),
            const SizedBox(height: Spacing.sm),
            ToggleRow(
              title: 'International leg',
              icon: Icons.public_rounded,
              value: shipment.isInternational,
              blurb: 'Reveals the customs reference and the commercial invoice.',
              lockedReason: (shipment.courier?.isInternational ?? false)
                  ? 'Forced on by ${shipment.courier!.label}.'
                  : null,
              enabled: enabled,
              onChanged: (value) => unawaited(_save(isInternational: value)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _valueCard(ShipmentLegView view, {required bool enabled}) {
    final shipment = view.shipment;
    final suggested = view.bundle.suggestedDeclaredValue;

    return DhSectionCard(
      title: 'Declared value and cover',
      subtitle: 'What the insurer is told this package is worth.',
      leading: const Icon(Icons.verified_user_outlined),
      child: Focus(
        onFocusChange: (hasFocus) {
          _editing = hasFocus;
          if (!hasFocus && _hasUnsaved) unawaited(_save());
          setState(() {});
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MoneyField(
              value: _declared,
              enabled: enabled,
              label: 'Declared value',
              helperText: suggested == null
                  ? 'No approved quote on this job yet, so there is no figure to check against.'
                  : 'The approved quote is ${suggested.format()}.',
              onCurrencyChanged: (code) =>
                  setState(() => _declared = Money(_declared.minor, code)),
              onChanged: (money) => setState(() => _declared = money),
              onSubmitted: (_) => unawaited(_save()),
            ),
            if (suggested != null && enabled) ...[
              const SizedBox(height: Spacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() => _declared = suggested);
                    unawaited(_save());
                  },
                  icon: const Icon(Icons.download_done_rounded, size: 18),
                  label: Text('Declare at ${suggested.format()}'),
                ),
              ),
            ],
            if (view.declaredValueUnderQuote) ...[
              const SizedBox(height: Spacing.sm),
              AdviceNote(
                tone: AdviceTone.risk,
                text: 'This leg is declared below the approved value of '
                    '${suggested!.format()}. A claim pays out against the declaration, not '
                    'against the quote.',
              ),
            ],
            const SizedBox(height: Spacing.md),
            ToggleRow(
              title: 'Insured in transit',
              icon: Icons.shield_outlined,
              value: shipment.insured,
              blurb: 'Switch it off only for a hand-carry you are personally accompanying.',
              enabled: enabled,
              onChanged: (value) => unawaited(_save(insured: value)),
            ),
          ],
        ),
      ),
    );
  }

  /// The branch the mockup declared and never built: Malca-Amit with no customs field anywhere.
  Widget _customsCard(ShipmentLegView view, {required bool enabled}) {
    final shipment = view.shipment;
    final invoice = view.commercialInvoice;

    return DhSectionCard(
      title: 'Customs',
      subtitle: 'An international leg needs a reference and a commercial invoice. Without both, '
          'dispatch is refused.',
      leading: const Icon(Icons.gavel_rounded),
      child: Focus(
        onFocusChange: (hasFocus) {
          _editing = hasFocus;
          if (!hasFocus && _hasUnsaved) unawaited(_save());
          setState(() {});
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabelledField(
              label: 'Customs reference',
              controller: _customsRef,
              enabled: enabled,
              mono: true,
              uppercase: true,
              hint: 'Shipping bill or AD code reference',
              helperText: 'HSN 7113 for articles of jewellery of precious metal.',
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => unawaited(_save()),
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'COMMERCIAL INVOICE',
              style: context.text.labelSmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.sm),
            if (invoice != null)
              AttachmentTile.row(
                item: attachmentViewOf(
                  invoice,
                  signedUrl: view.bundle.urlOf(invoice.id),
                ),
                onRetake: enabled ? () => unawaited(_attachCommercialInvoice()) : null,
              )
            else if (enabled)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => unawaited(_attachCommercialInvoice()),
                      icon: const Icon(Icons.upload_file_rounded, size: 18),
                      label: const Text('Attach a PDF'),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => unawaited(_photographPaperwork()),
                      icon: const Icon(Icons.photo_camera_outlined, size: 18),
                      label: const Text('Photograph it'),
                    ),
                  ),
                ],
              )
            else
              Text(
                'No commercial invoice was attached to this leg.',
                style: context.text.bodyMedium
                    ?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
            if (shipment.isInternational && shipment.needsCustomsPaperwork) ...[
              const SizedBox(height: Spacing.sm + Spacing.xs),
              const AdviceNote(
                tone: AdviceTone.risk,
                text: 'Customs paperwork is incomplete, so dispatch is held shut. The courier '
                    'will not accept the package without it either.',
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// What was signed for, once the leg is closed. The corpus had nothing here at all.
  Widget _deliveryRecord(ShipmentLegView view) {
    final shipment = view.shipment;
    final pod = view.proofOfDelivery;

    return DhSectionCard(
      title: view.isInbound ? 'Receipt' : 'Proof of delivery',
      leading: const Icon(Icons.assignment_turned_in_outlined),
      accent: pod == null ? context.scheme.error : context.dh.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DataPairGrid(
            children: [
              DataPair(label: 'Received by', value: shipment.receivedBy ?? ''),
              if (shipment.deliveredAt != null)
                DataPair.timestamp(label: 'At', utc: shipment.deliveredAt!),
              if (shipment.transitTime != null)
                DataPair.mono(
                  label: 'Transit',
                  value: shortSpan(shipment.transitTime!),
                ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          if (pod != null)
            AttachmentTile.row(item: attachmentViewOf(pod, signedUrl: view.proofUrl))
          else
            AdviceNote(
              tone: AdviceTone.risk,
              text: 'Nothing was signed for. Open the delivery record and attach a signature or '
                  'a photograph of the docket.',
              action: TextButton(
                onPressed: () => unawaited(
                  DeliveryConfirmScreen.push(
                    context,
                    jobId: _jobId,
                    shipmentId: shipment.id,
                  ),
                ),
                child: const Text('Attach'),
              ),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- footer

  Widget _footer(
    ShipmentLegView view, {
    required Permissions permissions,
    required ShippingTask? task,
  }) {
    final shipment = view.shipment;
    final busy = task != null;

    if (shipment.isDelivered) {
      return StickyActions(
        note: 'This leg is closed. Its record is what an insurer or a customer would be shown.',
        children: [
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () => unawaited(
                      DeliveryConfirmScreen.push(
                        context,
                        jobId: _jobId,
                        shipmentId: shipment.id,
                      ),
                    ),
            icon: const Icon(Icons.assignment_turned_in_outlined, size: 18),
            label: Text(view.isInbound ? 'Open the receipt' : 'Open the delivery record'),
          ),
        ],
      );
    }

    // An inbound leg was dispatched by somebody else, so the only act here is receiving it.
    if (view.isInbound) {
      return StickyActions(
        blockedReason: view.deliveryBlockedReason,
        note: 'Goods arriving are checked against the docket before anyone signs for them.',
        children: [
          FilledButton.icon(
            onPressed: view.canConfirmDelivery && !busy
                ? () => unawaited(
                      DeliveryConfirmScreen.push(
                        context,
                        jobId: _jobId,
                        shipmentId: shipment.id,
                      ),
                    )
                : null,
            icon: const Icon(Icons.inventory_2_outlined, size: 18),
            label: Text(view.deliveryVerb),
          ),
        ],
      );
    }

    if (shipment.status.isInFlight) {
      return StickyActions(
        blockedReason: view.deliveryBlockedReason,
        children: [
          FilledButton.icon(
            onPressed: view.canConfirmDelivery && !busy
                ? () => unawaited(
                      DeliveryConfirmScreen.push(
                        context,
                        jobId: _jobId,
                        shipmentId: shipment.id,
                      ),
                    )
                : null,
            icon: const Icon(Icons.how_to_reg_outlined, size: 18),
            label: const Text('Confirm delivery'),
          ),
          if (shipment.status == ShipmentStatus.dispatched) ...[
            const SizedBox(height: Spacing.sm),
            OutlinedButton.icon(
              onPressed: busy ? null : () => unawaited(_markInTransit()),
              icon: task == ShippingTask.inTransit
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.moving_rounded, size: 18),
              label: const Text('Mark in transit'),
            ),
          ],
        ],
      );
    }

    // Draft, outbound: the dispatch gate.
    final permissionBlock = permissions.blockReason(Capability.dispatch);
    return StickyActions(
      blockedReason: view.dispatchBlockedReason ?? permissionBlock,
      note: _hasUnsaved
          ? 'What you typed is saved before the package goes out.'
          : 'Dispatch is refused while any protocol step is outstanding.',
      children: [
        FilledButton.icon(
          onPressed: view.canDispatch && permissions.canDispatch && !busy
              ? () => unawaited(_dispatch())
              : null,
          icon: task == ShippingTask.dispatch
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.outbound_rounded, size: 18),
          label: const Text('Confirm Dispatch'),
        ),
      ],
    );
  }
}
