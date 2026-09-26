/// Proof of delivery — the act the corpus never had.
///
/// "Confirm Dispatch" was the last wired action in all 46 mockups. Nothing knew what happened
/// after the van left: no arrival, no recipient, no signature, and therefore no way to answer the
/// only question that matters when a $45,000 package goes missing — who took it, and when.
///
/// This screen closes that. It records:
///
///  * **who received it**, typed, because `shipments.received_by` is the name a claim is made
///    against and a blank one makes the whole record worthless;
///  * **when**, defaulted to now and refused if it is in the future or before the leg was
///    dispatched — a delivery cannot precede its own departure;
///  * **the proof itself**, as a real file in `attachments`: a signature drawn on the screen, a
///    photograph of the courier's docket, or a PDF the courier emailed.
///
/// Confirming the delivery of a final dispatch also closes the `dispatch` stage, which moves the
/// job to `delivered` (D-005 — the rail is the truth, and the rail should say the piece is with
/// the customer). Closing the order itself is a separate, explicit act, because finishing a job
/// is not something to do to somebody by side effect.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/shipping/shipping_actions.dart';
import 'package:dhanaos/features/shipping/shipping_gateway.dart';
import 'package:dhanaos/features/shipping/shipping_widgets.dart';
import 'package:dhanaos/features/shipping/signature_pad.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// How the handover is evidenced.
enum ProofKind {
  /// Drawn on the glass. The common case at a retailer's counter.
  signature('Signature', Icons.draw_outlined),

  /// A photograph of the courier's own docket, which already carries a signature.
  photo('Photo', Icons.photo_camera_outlined),

  /// A PDF the courier emailed through.
  file('File', Icons.attach_file_rounded);

  const ProofKind(this.label, this.icon);

  final String label;
  final IconData icon;
}

final class DeliveryConfirmScreen extends ConsumerWidget {
  const DeliveryConfirmScreen({
    super.key,
    required this.jobId,
    required this.shipmentId,
  });

  final String jobId;
  final String shipmentId;

  static Future<void> push(
    BuildContext context, {
    required String jobId,
    required String shipmentId,
  }) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DeliveryConfirmScreen(jobId: jobId, shipmentId: shipmentId),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(shippingBundleProvider(jobId));

    return async.when(
      loading: () => const _Frame(
        title: 'Delivery',
        child: Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoadingSkeleton(height: 72),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
            ],
          ),
        ),
      ),
      error: (error, _) => _Frame(
        title: 'Delivery',
        child: ErrorState(
          title: 'The delivery record did not open',
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
            title: 'Delivery',
            child: ErrorState(
              icon: Icons.no_transfer_outlined,
              title: 'That leg is no longer on this job',
              message: 'It was removed, or it belongs to a different job order.',
              onSecondary: () => Navigator.of(context).maybePop(),
              secondaryLabel: 'Go back',
            ),
          );
        }
        return _DeliveryForm(key: ValueKey(shipmentId), view: view);
      },
    );
  }
}

final class _Frame extends StatelessWidget {
  const _Frame({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: child,
      );
}

// ================================================================= form

final class _DeliveryForm extends ConsumerStatefulWidget {
  const _DeliveryForm({super.key, required this.view});

  final ShipmentLegView view;

  @override
  ConsumerState<_DeliveryForm> createState() => _DeliveryFormState();
}

class _DeliveryFormState extends ConsumerState<_DeliveryForm> {
  late final TextEditingController _receivedBy =
      TextEditingController(text: widget.view.shipment.receivedBy ?? '');
  final SignatureController _signature = SignatureController();

  late DateTime _at = _defaultArrival();
  ProofKind _proof = ProofKind.signature;
  File? _proofFile;
  String? _proofName;

  Shipment get _shipment => widget.view.shipment;

  String get _jobId => widget.view.bundle.job.id;

  /// Now, unless the leg was dispatched in the future-facing minute of a clock skew — in which
  /// case start from the dispatch instant so the form is never born invalid.
  DateTime _defaultArrival() {
    final now = DateTime.now();
    final out = widget.view.shipment.dispatchedAt?.toLocal();
    return out != null && out.isAfter(now) ? out : now;
  }

  @override
  void initState() {
    super.initState();
    // Both the gate and the "no proof" warning read these, so a keystroke and a stroke each have
    // to reach the frame.
    _receivedBy.addListener(_onTyped);
    _signature.addListener(_onTyped);
  }

  void _onTyped() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _receivedBy
      ..removeListener(_onTyped)
      ..dispose();
    _signature
      ..removeListener(_onTyped)
      ..dispose();
    super.dispose();
  }

  // -------------------------------------------------------------- validation

  String? get _timeProblem {
    final now = DateTime.now();
    // Five minutes of slack: a shop-floor tablet's clock is not a reference standard.
    if (_at.isAfter(now.add(const Duration(minutes: 5)))) {
      return 'A delivery cannot be recorded in the future. Set the time it actually arrived.';
    }
    final out = _shipment.dispatchedAt?.toLocal();
    if (out != null && _at.isBefore(out)) {
      return 'This leg was dispatched at ${localTimestamp(_shipment.dispatchedAt!)}. It cannot '
          'have arrived before it left.';
    }
    return null;
  }

  bool get _hasName => _receivedBy.text.trim().isNotEmpty;

  bool get _hasProof => switch (_proof) {
        ProofKind.signature => _signature.isNotEmpty,
        ProofKind.photo || ProofKind.file => _proofFile != null,
      };

  /// The gate, worst problem first.
  String? get _blockedReason {
    final leg = widget.view.deliveryBlockedReason;
    if (leg != null) return leg;
    if (!_hasName) {
      return 'Type who took the package. A handover with no name on it is not a record of '
          'anything.';
    }
    return _timeProblem;
  }

  bool get _canSubmit =>
      widget.view.canConfirmDelivery && _hasName && _timeProblem == null;

  // -------------------------------------------------------------- pickers

  Future<void> _pickDate() async {
    final out = _shipment.dispatchedAt?.toLocal();
    final picked = await showDatePicker(
      context: context,
      initialDate: _at,
      firstDate: out ?? _at.subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: 'Date it arrived',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _at = DateTime(picked.year, picked.month, picked.day, _at.hour, _at.minute);
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
      helpText: 'Time it arrived',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _at = DateTime(_at.year, _at.month, _at.day, picked.hour, picked.minute);
    });
  }

  Future<void> _photograph() async {
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
    setState(() {
      _proofFile = File(file.path);
      _proofName = file.name;
    });
  }

  Future<void> _chooseFile() async {
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: 'Proof of delivery',
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
      );
    } on Exception catch (error) {
      if (!mounted) return;
      showFailure(
        context,
        StorageFailure(
          message: 'The file browser could not be opened. Photograph the docket instead.',
          detail: error.toString(),
        ),
      );
      return;
    }
    final chosen = picked;
    if (chosen == null || !mounted) return;
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
    setState(() {
      _proofFile = File(path);
      _proofName = chosen.name;
    });
  }

  // -------------------------------------------------------------- submit

  Future<FileUpload?> _buildProof() async {
    switch (_proof) {
      case ProofKind.signature:
        if (_signature.isEmpty) return null;
        final bytes = await _signature.toPng(
          pixelRatio: mounted ? MediaQuery.devicePixelRatioOf(context) : 3,
        );
        if (bytes == null) return null;
        final code = widget.view.bundle.job.displayCode.replaceAll(RegExp('[^A-Za-z0-9-]'), '');
        return FileUpload.bytes(
          filename: 'pod-$code-${_shipment.leg.wire}.png',
          bytes: bytes,
          caption: 'Signature of ${_receivedBy.text.trim()}',
        );
      case ProofKind.photo:
      case ProofKind.file:
        final file = _proofFile;
        if (file == null) return null;
        return FileUpload.file(
          file,
          filename: _proofName,
          caption: 'Proof of delivery — ${_receivedBy.text.trim()}',
        );
    }
  }

  Future<void> _confirm() async {
    final view = widget.view;
    final recipient = _receivedBy.text.trim();
    final advance = view.isFinalDispatch ? view.bundle.advanceNote : null;

    final agreed = await confirmAction(
      context,
      title: view.isInbound ? 'Record this receipt?' : 'Confirm this delivery?',
      message: [
        '${view.shipment.leg.label} ${view.isInbound ? 'received' : 'delivered'} to '
            '$recipient at ${localTimestamp(_at.toUtc())}.',
        if (_hasProof)
          _proof == ProofKind.signature
              ? 'The signature is filed against this shipment as an image.'
              : 'The file is filed against this shipment.'
        else
          'NO proof will be attached. An undocumented handover of a high-value piece cannot be '
              'defended later.',
        if (advance != null) advance,
        if (advance == null && view.isFinalDispatch)
          'This also closes the Dispatch stage and moves the job to Delivered.',
        'The record is written to the audit trail and cannot be edited afterwards.',
      ].join('\n\n'),
      confirmLabel: view.isInbound ? 'Record it' : 'Confirm delivery',
      cancelLabel: 'Not yet',
    );
    if (!agreed || !mounted) return;

    FileUpload? proof;
    try {
      proof = await _buildProof();
    } on Object catch (error, stack) {
      if (!mounted) return;
      showFailure(context, toDhFailure(error, stack));
      return;
    }
    if (!mounted) return;

    try {
      await ref.read(shippingActionsProvider.notifier).confirmDelivery(
            jobId: _jobId,
            view: view,
            deliveredAt: _at,
            receivedBy: recipient,
            proof: proof,
          );
      if (!mounted) return;
      showDone(
        context,
        view.isInbound
            ? 'Receipt recorded for ${view.shipment.leg.label}.'
            : 'Delivery recorded. Signed for by $recipient.',
      );
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _closeOrder() async {
    final stage = widget.view.bundle.stageToCloseOnJobClose;
    if (stage == null) return;

    final agreed = await confirmAction(
      context,
      title: 'Close this job order?',
      message: 'The piece is with the customer and every stage is settled. Closing stamps the '
          'order complete and takes it off the production board.\n\n'
          'Reopening a closed order is not something this app does — a further change becomes a '
          'new job.',
      confirmLabel: 'Close the order',
      cancelLabel: 'Leave it open',
    );
    if (!agreed || !mounted) return;

    try {
      await ref.read(shippingActionsProvider.notifier).closeJob(
            jobId: _jobId,
            deliveredStage: stage,
          );
      if (!mounted) return;
      showDone(context, 'Job order closed.');
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
    final mayRecord = permissions.canDispatch || permissions.canEditJob;

    return Scaffold(
      appBar: AppBar(
        title: Text(view.isInbound ? 'Receipt' : 'Proof of delivery'),
        actions: [
          IconButton(
            onPressed: busy ? null : () => ref.invalidate(shippingBundleProvider(_jobId)),
            tooltip: 'Re-read this leg',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xl),
        children: [
          _header(view),
          if (shipment.isDelivered) ...[
            const SizedBox(height: Spacing.md),
            _record(view),
          ] else ...[
            const SizedBox(height: Spacing.md),
            _recipientCard(enabled: mayRecord && !busy),
            const SizedBox(height: Spacing.md),
            _arrivalCard(enabled: mayRecord && !busy),
            const SizedBox(height: Spacing.md),
            _proofCard(enabled: mayRecord && !busy),
          ],
        ],
      ),
      bottomNavigationBar: _footer(
        view,
        busy: busy,
        task: task,
        mayRecord: mayRecord,
      ),
    );
  }

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
                size: 20,
                color: context.scheme.onSurfaceVariant,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(child: Text(shipment.leg.label, style: context.text.titleMedium)),
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
              DataPair(
                label: 'Courier',
                value: shipment.courier == null ? '' : shipment.courierLabel,
              ),
              DataPair.mono(label: 'Waybill', value: shipment.waybill ?? ''),
              if (shipment.declaredValue != null)
                DataPair.money(
                  label: 'Declared',
                  amount: shipment.declaredValue!,
                  emphasis: DataEmphasis.normal,
                ),
              if (shipment.dispatchedAt != null)
                DataPair.timestamp(label: 'Dispatched', utc: shipment.dispatchedAt!),
            ],
          ),
          if (shipment.signatureReq && !shipment.isDelivered) ...[
            const SizedBox(height: Spacing.md),
            const AdviceNote(
              tone: AdviceTone.consequence,
              text: 'This leg was sent signature-required. Capture the recipient\'s signature '
                  'rather than leaving the proof blank.',
            ),
          ],
        ],
      ),
    );
  }

  Widget _recipientCard({required bool enabled}) => DhSectionCard(
        title: 'Received by',
        subtitle: widget.view.isInbound
            ? 'Who at the workshop took the package in.'
            : 'The name of the person who actually signed for it.',
        leading: const Icon(Icons.person_outline_rounded),
        child: LabelledField(
          label: 'Full name',
          controller: _receivedBy,
          enabled: enabled,
          hint: 'Kavita Rao',
          helperText: 'Not the shop name. A claim is made against a person.',
        ),
      );

  Widget _arrivalCard({required bool enabled}) {
    final problem = _timeProblem;

    return DhSectionCard(
      title: 'Arrived',
      leading: const Icon(Icons.schedule_rounded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: enabled ? () => unawaited(_pickDate()) : null,
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text(localTimestamp(_at.toUtc(), withTime: false)),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: enabled ? () => unawaited(_pickTime()) : null,
                  icon: const Icon(Icons.access_time_rounded, size: 18),
                  label: Text(
                    TimeOfDay.fromDateTime(_at).format(context),
                  ),
                ),
              ),
            ],
          ),
          if (problem != null) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            AdviceNote(tone: AdviceTone.risk, text: problem),
          ],
          if (_shipment.dispatchedAt != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              'Dispatched ${localTimestamp(_shipment.dispatchedAt!)}',
              style: AppTheme.mono(size: 10.5, color: context.scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _proofCard({required bool enabled}) {
    final name = _proofName;

    return DhSectionCard(
      title: 'Proof',
      subtitle: 'A signature, a photograph of the courier docket, or the PDF the courier sent.',
      leading: const Icon(Icons.assignment_turned_in_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DhSegmented<ProofKind>(
            segments: [
              for (final kind in ProofKind.values)
                DhSegment<ProofKind>(
                  value: kind,
                  label: kind.label,
                  icon: kind.icon,
                  enabled: enabled,
                  disabledReason: 'This handover is already on the record.',
                ),
            ],
            value: _proof,
            onChanged: (kind) => setState(() => _proof = kind),
          ),
          const SizedBox(height: Spacing.md),
          switch (_proof) {
            ProofKind.signature => SignaturePad(
                controller: _signature,
                enabled: enabled,
                hint: widget.view.isInbound
                    ? 'The receiving operator signs here'
                    : 'The recipient signs here',
              ),
            ProofKind.photo => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (name != null)
                    Text(
                      name,
                      style: AppTheme.mono(size: 12.5, color: context.scheme.onSurface),
                    ),
                  if (name != null) const SizedBox(height: Spacing.sm),
                  OutlinedButton.icon(
                    onPressed: enabled ? () => unawaited(_photograph()) : null,
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    label: Text(name == null ? 'Photograph the docket' : 'Retake'),
                  ),
                ],
              ),
            ProofKind.file => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (name != null)
                    Text(
                      name,
                      style: AppTheme.mono(size: 12.5, color: context.scheme.onSurface),
                    ),
                  if (name != null) const SizedBox(height: Spacing.sm),
                  OutlinedButton.icon(
                    onPressed: enabled ? () => unawaited(_chooseFile()) : null,
                    icon: const Icon(Icons.attach_file_rounded, size: 18),
                    label: Text(name == null ? 'Choose a file' : 'Choose another'),
                  ),
                ],
              ),
          },
          if (!_hasProof) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            const AdviceNote(
              tone: AdviceTone.risk,
              text: 'Nothing captured yet. The delivery can still be recorded without proof, and '
                  'the leg will carry a warning until one is attached.',
            ),
          ],
        ],
      ),
    );
  }

  /// The settled record. This is what an insurer or a customer would be shown.
  Widget _record(ShipmentLegView view) {
    final shipment = view.shipment;
    final pod = view.proofOfDelivery;
    final url = view.proofUrl;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DhSectionCard(
          title: view.isInbound ? 'Receipt' : 'Delivery record',
          leading: const Icon(Icons.verified_rounded),
          accent: pod == null ? context.scheme.error : context.dh.success,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DataPairGrid(
                children: [
                  DataPair(label: 'Received by', value: shipment.receivedBy ?? ''),
                  if (shipment.deliveredAt != null)
                    DataPair.timestamp(label: 'Arrived', utc: shipment.deliveredAt!),
                  if (shipment.transitTime != null)
                    DataPair.mono(
                      label: 'Transit',
                      value: shortSpan(shipment.transitTime!),
                    ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              if (pod != null) ...[
                AttachmentTile.row(item: attachmentViewOf(pod, signedUrl: url)),
                if (url != null) ...[
                  const SizedBox(height: Spacing.sm + Spacing.xs),
                  ClipRRect(
                    borderRadius: Radii.rMd,
                    child: Image.network(
                      url,
                      height: 180,
                      fit: BoxFit.contain,
                      // A proof that will not render is a cosmetic problem, not a lost file.
                      errorBuilder: (context, _, __) => Text(
                        'The stored proof could not be previewed. The file is still attached.',
                        style: context.text.bodySmall
                            ?.copyWith(color: context.scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                ],
              ] else
                const AdviceNote(
                  tone: AdviceTone.risk,
                  text: 'This handover was recorded with no proof attached.',
                ),
            ],
          ),
        ),
        if (view.isFinalDispatch) ...[
          const SizedBox(height: Spacing.md),
          _closingCard(view),
        ],
      ],
    );
  }

  /// The end of the line. Nothing in the corpus finished a job at all.
  Widget _closingCard(ShipmentLegView view) {
    final closable = view.bundle.isJobClosable;
    final active = view.bundle.rail.activeStage;

    return DhSectionCard(
      title: 'The job order',
      leading: const Icon(Icons.flag_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdviceNote(
            tone: closable ? AdviceTone.consequence : AdviceTone.info,
            text: closable
                ? 'Every stage is settled and the piece is with the customer. Closing the order '
                    'stamps it complete and takes it off the production board.'
                : active == null
                    ? 'This job has no active stage, so there is nothing left to close here.'
                    : 'The job is standing at ${active.stage.label}. It can be closed once the '
                        'rail reaches Delivered.',
          ),
        ],
      ),
    );
  }

  Widget _footer(
    ShipmentLegView view, {
    required bool busy,
    required ShippingTask? task,
    required bool mayRecord,
  }) {
    if (view.shipment.isDelivered) {
      return StickyActions(
        note: view.bundle.isJobClosable
            ? null
            : 'This leg is closed. Its record is what an insurer or a customer would be shown.',
        children: [
          if (view.isFinalDispatch && view.bundle.isJobClosable)
            FilledButton.icon(
              onPressed: busy || !mayRecord ? null : () => unawaited(_closeOrder()),
              icon: task == ShippingTask.closeJob
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.flag_rounded, size: 18),
              label: const Text('Close the job order'),
            )
          else
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('Back to the leg'),
            ),
        ],
      );
    }

    return StickyActions(
      blockedReason: mayRecord
          ? _blockedReason
          : 'Only Logistics, Production Manager or Engineer can record a delivery.',
      note: _hasProof
          ? null
          : 'A delivery with no proof is allowed, and the leg will say so until one is attached.',
      children: [
        FilledButton.icon(
          onPressed: _canSubmit && mayRecord && !busy ? () => unawaited(_confirm()) : null,
          icon: task == ShippingTask.deliver
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.how_to_reg_outlined, size: 18),
          label: Text(view.deliveryVerb),
        ),
      ],
    );
  }
}
