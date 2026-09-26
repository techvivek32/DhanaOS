/// Taking custody of a client's own materials.
///
/// **This screen is absent from all 46 mockups.** `customer_supplied` rendered "Verified & Logged
/// in Inventory" as a green status chip and captured nothing at all: no declared value, no
/// verifier, no timestamp, no receipt number, no photographs, no certificate and no risk
/// acknowledgement. The corpus had a `Reset Stone` job type, so the shop was designed to accept a
/// client's $12,500 diamond across a counter with no record of what it had taken. That is legal
/// and insurance exposure, not a process.
///
/// So the record is complete or it is not made. Four things are required together and the button
/// stays shut until they are there, naming what is missing:
///
///   1. a description of what is being handed over — the line a claim would be read against;
///   2. the value the client declares, in the job's own currency;
///   3. the verifier, which is the signed-in operator and never a typed name (D-008);
///   4. the client's acknowledgement of the risk terms.
///
/// Photographs, a signature and an insurance reference are pressed for but not required to *make*
/// the record: a client can be standing at the counter before the camera is ready, and a receipt
/// refused for a missing photo is a client walking out with no receipt at all.
/// [GoodsInReceipt.missingEvidence] is what chases them afterwards, from the custody list at the
/// top of this screen.
///
/// When the receipt is tied to a client-supplied stone line, the same facts are stamped onto that
/// stone — `SpecRepository.recordCustody` — so the intake step's custody gate is satisfied by the
/// act at the counter rather than by someone remembering a second screen.
library;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/inventory/inventory_actions.dart';
import 'package:dhanaos/features/inventory/inventory_gateway.dart';
import 'package:dhanaos/features/inventory/inventory_widgets.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/shipping/signature_pad.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// The risk statement, in one place. It is read to the client, so it is written to be read out
/// loud — not as terms and conditions.
const _riskStatement = 'Setting, sizing and polishing a client-owned stone carries a real risk of '
    'chipping or loss. While the stone is in this workshop it is insured at the value declared '
    'here, and nothing more.';

/// Open the goods-in counter for one job.
Future<void> openGoodsIn(BuildContext context, String jobId) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => GoodsInScreen(jobId: jobId)),
    );

final class GoodsInScreen extends ConsumerWidget {
  const GoodsInScreen({super.key, required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final custody = ref.watch(goodsInContextProvider(jobId));

    return Scaffold(
      backgroundColor: context.scheme.surface,
      appBar: AppBar(
        title: const Text('Client goods in'),
        actions: [
          IconButton(
            tooltip: 'Re-read the custody record',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref.invalidate(goodsInContextProvider(jobId)),
          ),
        ],
      ),
      body: switch (custody) {
        AsyncValue(value: final loaded?) => _Body(ctx: loaded),
        AsyncError(error: final error) => ErrorState(
            title: 'The custody record did not load',
            message: error is DhFailure
                ? error.message
                : 'Check the connection and try again. Nothing has been recorded.',
            detail: error is DhFailure ? error.detail : null,
            onRetry: () => ref.invalidate(goodsInContextProvider(jobId)),
          ),
        _ => const Padding(
            padding: EdgeInsets.all(Spacing.md),
            child: Column(
              children: [
                LoadingSkeleton.card(),
                SizedBox(height: Spacing.md),
                LoadingSkeleton.lines(count: 4),
              ],
            ),
          ),
      },
    );
  }
}

final class _Body extends ConsumerWidget {
  const _Body({required this.ctx});

  final GoodsInContext ctx;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(permissionsProvider);
    final blocked = permissions.blockReason(Capability.moveStock);

    return ListView(
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xxl),
      children: [
        _JobHeader(ctx: ctx),
        if (ctx.receipts.isNotEmpty) ...[
          const SizedBox(height: Spacing.md),
          _CustodyList(ctx: ctx),
        ],
        const SizedBox(height: Spacing.md),
        if (blocked != null)
          VaultNote(tone: VaultNoteTone.risk, icon: Icons.lock_outline_rounded, text: blocked)
        else
          // Keyed on the job so opening a different job's counter starts a clean form, and on the
          // receipt count so a recorded receipt clears the fields it was made from.
          _GoodsInForm(
            key: ValueKey('${ctx.job.id}:${ctx.receipts.length}'),
            ctx: ctx,
          ),
      ],
    );
  }
}

// ================================================================= job header

final class _JobHeader extends StatelessWidget {
  const _JobHeader({required this.ctx});

  final GoodsInContext ctx;

  @override
  Widget build(BuildContext context) {
    final job = ctx.job;
    final inCustody = ctx.inCustody;

    return DhCard(
      accent: inCustody.isEmpty ? null : context.dh.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusChip.code(job.displayCode, dense: true),
              const SizedBox(width: Spacing.sm),
              if (job.jobType != null) StatusChip(label: job.jobType!.label, dense: true),
              const Spacer(),
              StatusChip.job(job.status, dense: true),
            ],
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          Text(job.displayTitle, style: context.text.titleMedium),
          if (ctx.customer != null) ...[
            const SizedBox(height: 2),
            Text(
              ctx.customer!.displayName,
              style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: Spacing.md),
          DataPairGrid(
            children: [
              DataPair.money(
                label: 'Value in our care',
                amount: ctx.valueInCustody,
                emphasis: DataEmphasis.display,
              ),
              DataPair.mono(
                label: 'Items held',
                value: '${inCustody.length}',
                emphasis: DataEmphasis.strong,
              ),
              DataPair.mono(
                label: 'Priced in',
                value: ctx.currency,
                tooltip: 'The job’s currency. A declared value is entered in it, because storing '
                    'paise as cents is an eighty-fold error on an insurance figure.',
              ),
            ],
          ),
          if (!ctx.jobTypeExpectsCustody) ...[
            const SizedBox(height: Spacing.md),
            VaultNote(
              text: 'This job is a ${job.jobType?.label ?? 'standard job'}, not a Reset Stone. '
                  'Taking client materials in is still fine — a repair often arrives with the '
                  'client’s own piece — it is just worth a second look.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= what we hold

final class _CustodyList extends ConsumerWidget {
  const _CustodyList({required this.ctx});

  final GoodsInContext ctx;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(inventoryActionsProvider) != null;

    return DhSectionCard(
      title: 'In our care',
      subtitle: 'Each line is a receipt the client can quote back at you.',
      leading: const Icon(Icons.inventory_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final receipt in ctx.receipts) ...[
            _ReceiptCard(ctx: ctx, receipt: receipt, busy: busy),
            const SizedBox(height: Spacing.sm),
          ],
        ],
      ),
    );
  }
}

final class _ReceiptCard extends ConsumerWidget {
  const _ReceiptCard({required this.ctx, required this.receipt, required this.busy});

  final GoodsInContext ctx;
  final GoodsInReceipt receipt;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final missing = receipt.missingEvidence;
    final photos = [
      for (final id in receipt.photoIds)
        if (ctx.file(id) != null) ctx.file(id)!,
    ];

    return DhCard(
      tone: DhCardTone.inset,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusChip.code(receipt.receiptCode, dense: true),
              const SizedBox(width: Spacing.sm),
              if (receipt.isInCustody)
                StatusChip(
                  label: custodySpan(receipt.custodyDuration),
                  tone: ChipTone.warning,
                  dense: true,
                  icon: Icons.schedule_rounded,
                )
              else
                const StatusChip(
                  label: 'Returned',
                  tone: ChipTone.success,
                  dense: true,
                  icon: Icons.check_rounded,
                ),
              const Spacer(),
              Text(
                receipt.declaredValue.format(),
                style: AppTheme.mono(
                  size: 14,
                  weight: FontWeight.w600,
                  color: context.scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(receipt.description, style: context.text.bodyLarge),
          const SizedBox(height: Spacing.sm),
          DataPairGrid(
            children: [
              DataPair.timestamp(label: 'Taken in', utc: receipt.receivedAt),
              DataPair.mono(
                label: 'Verified by',
                // D-008: a name is only rendered for the session user. Another operator's id is
                // shown short rather than resolved into a name this screen cannot vouch for.
                value: receipt.receivedBy == ctx.verifierId
                    ? (ctx.verifierName ?? 'You')
                    : '${receipt.receivedBy.substring(0, 8)}…',
                tooltip: receipt.receivedBy == ctx.verifierId
                    ? 'You took these goods in.'
                    : 'Another operator took these goods in. Their full record is on the job’s '
                        'activity trail.',
              ),
              DataPair.mono(
                label: 'Insurance ref',
                value: receipt.insuranceRef ?? DataPair.placeholder,
              ),
              if (receipt.returnedAt != null)
                DataPair.timestamp(label: 'Handed back', utc: receipt.returnedAt!),
            ],
          ),
          if (photos.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            AttachmentGrid(
              items: [
                for (final file in photos)
                  AttachmentView(
                    id: file.id,
                    kind: file.kind,
                    filename: file.filename,
                    meta: file.metaLabel,
                    thumbnail: ctx.urlFor(file.id) == null
                        ? null
                        : CachedNetworkImageProvider(ctx.urlFor(file.id)!),
                  ),
              ],
            ),
          ],
          if (receipt.isInCustody && missing.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            VaultNote(
              tone: VaultNoteTone.risk,
              icon: Icons.fact_check_outlined,
              text: 'Still missing from this record: ${missing.join(', ').toLowerCase()}. An '
                  'insurer asks for exactly these.',
            ),
          ],
          if (receipt.isInCustody) ...[
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                if (missing.isNotEmpty)
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: busy ? null : () => unawaited(_addEvidence(context, ref)),
                      icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                      label: const Text('Add evidence'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(Spacing.rowHeight),
                      ),
                    ),
                  ),
                if (missing.isNotEmpty) const SizedBox(width: Spacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : () => unawaited(_handBack(context, ref)),
                    icon: const Icon(Icons.assignment_return_outlined, size: 18),
                    label: const Text('Hand it back'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(Spacing.rowHeight),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Completing a record after the client has left the counter.
  ///
  /// This is what makes "you can add it later" a true statement rather than a comforting one: the
  /// receipt was allowed to be made without photographs so a client would never leave empty
  /// handed, and this is the path back to finish it.
  Future<void> _addEvidence(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<_EvidenceKind>(
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
                'Complete ${receipt.receiptCode}',
                style: sheetContext.text.headlineSmall,
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                'Still missing: ${receipt.missingEvidence.join(', ').toLowerCase()}.',
                style: sheetContext.text.bodySmall
                    ?.copyWith(color: sheetContext.scheme.onSurfaceVariant),
              ),
              const SizedBox(height: Spacing.md),
              for (final kind in _EvidenceKind.values) ...[
                SelectableTile(
                  title: kind.label,
                  blurb: kind.blurb,
                  icon: kind.icon,
                  onTap: () => Navigator.of(sheetContext).pop(kind),
                ),
                const SizedBox(height: Spacing.sm),
              ],
            ],
          ),
        ),
      ),
    );
    if (choice == null || !context.mounted) return;

    switch (choice) {
      case _EvidenceKind.photo:
        await _attachFile(context, ref, asCertificate: false);
      case _EvidenceKind.certificate:
        await _attachFile(context, ref, asCertificate: true);
      case _EvidenceKind.signature:
        await _attachSignature(context, ref);
      case _EvidenceKind.insurance:
        await _attachInsuranceRef(context, ref);
    }
  }

  Future<void> _attachFile(
    BuildContext context,
    WidgetRef ref, {
    required bool asCertificate,
  }) async {
    final source = await pickVaultFileSource(
      context,
      title: asCertificate ? 'Attach the certificate' : 'Photograph the goods',
      blurb: asCertificate
          ? 'The lab report the client left with the stone.'
          : 'Photograph the goods as they are now, including any damage that was already there.',
    );
    if (source == null || !context.mounted) return;

    try {
      final picked = await takeVaultFile(source);
      if (picked == null || !context.mounted) return;

      final attachment = await ref.read(attachmentStoreProvider).upload(
            UploadRequest.file(
              orgId: ctx.job.orgId,
              kind: asCertificate ? AttachmentKind.certificatePdf : AttachmentKind.stonePhoto,
              file: picked.file,
              filename: picked.filename,
              jobId: ctx.job.id,
              caption: '${asCertificate ? 'Client certificate' : 'Condition photograph'} — '
                  '${receipt.receiptCode}',
            ),
          );
      await ref.read(inventoryActionsProvider.notifier).attachEvidence(
            receipt: receipt,
            photoIds: asCertificate ? null : [...receipt.photoIds, attachment.id],
            certId: asCertificate ? attachment.id : null,
          );
      if (!context.mounted) return;
      showDone(context, '${picked.filename} added to ${receipt.receiptCode}.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _attachSignature(BuildContext context, WidgetRef ref) async {
    final bytes = await showModalBottomSheet<Uint8List>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _SignatureSheet(receiptCode: receipt.receiptCode),
    );
    if (bytes == null || !context.mounted) return;

    final code = receipt.receiptCode.replaceAll(RegExp('[^A-Za-z0-9-]'), '');
    try {
      final attachment = await ref.read(attachmentStoreProvider).upload(
            UploadRequest.bytes(
              orgId: ctx.job.orgId,
              kind: AttachmentKind.proofOfDelivery,
              filename: 'goods-in-$code.png',
              bytes: bytes,
              jobId: ctx.job.id,
              caption: 'Client signature at goods-in — $code',
            ),
          );
      await ref.read(inventoryActionsProvider.notifier).attachEvidence(
            receipt: receipt,
            customerSigId: attachment.id,
          );
      if (!context.mounted) return;
      showDone(context, 'Signature added to ${receipt.receiptCode}.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _attachInsuranceRef(BuildContext context, WidgetRef ref) async {
    final value = await promptForText(
      context,
      title: 'Insurance reference',
      message: 'The policy or endorsement that ${receipt.declaredValue.format()} of client '
          'property sits under while it is here.',
      fieldLabel: 'Policy or endorsement',
      hint: 'POL-4471 / endorsement 12',
      submitLabel: 'Save the reference',
      minLines: 1,
    );
    if (value == null || !context.mounted) return;
    try {
      await ref.read(inventoryActionsProvider.notifier).attachEvidence(
            receipt: receipt,
            insuranceRef: value,
          );
      if (!context.mounted) return;
      showDone(context, 'Insurance reference saved against ${receipt.receiptCode}.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }

  /// Closing the custody window. Irreversible in the sense that matters — the register will say
  /// the goods left — so it is confirmed and asks who took them.
  Future<void> _handBack(BuildContext context, WidgetRef ref) async {
    final note = await promptForText(
      context,
      title: 'Hand back ${receipt.receiptCode}?',
      message: 'This closes the custody record. ${receipt.declaredValue.format()} of client '
          'property leaves the workshop, so say who collected it.',
      fieldLabel: 'Who collected it, and when',
      hint: 'Collected by R. Shah at the counter',
      submitLabel: 'Record the hand-back',
      minLines: 2,
    );
    if (note == null || !context.mounted) return;
    try {
      await ref.read(inventoryActionsProvider.notifier).returnGoods(
            receipt: receipt,
            note: note,
          );
      if (!context.mounted) return;
      showDone(context, '${receipt.receiptCode} handed back and closed.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }
}

/// The four things a receipt can still be missing after the client has gone.
enum _EvidenceKind {
  photo(
    'Add a condition photo',
    Icons.add_a_photo_outlined,
    'What the goods looked like when they arrived',
  ),
  certificate(
    'Attach the certificate',
    Icons.description_outlined,
    'The grading report the client brought',
  ),
  signature(
    'Capture the signature',
    Icons.draw_outlined,
    'Ask the client to sign next time they are in',
  ),
  insurance(
    'Add the insurance reference',
    Icons.shield_outlined,
    'The policy this value sits under',
  );

  const _EvidenceKind(this.label, this.icon, this.blurb);

  final String label;
  final IconData icon;
  final String blurb;
}

/// A signature on its own, for completing a receipt that was made without one.
final class _SignatureSheet extends StatefulWidget {
  const _SignatureSheet({required this.receiptCode});

  final String receiptCode;

  @override
  State<_SignatureSheet> createState() => _SignatureSheetState();
}

class _SignatureSheetState extends State<_SignatureSheet> {
  final SignatureController _controller = SignatureController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final bytes = await _controller.toPng(
      pixelRatio: mounted ? MediaQuery.devicePixelRatioOf(context) : 3,
    );
    if (!mounted || bytes == null) return;
    Navigator.of(context).pop(bytes);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Signature for ${widget.receiptCode}', style: context.text.headlineSmall),
              const SizedBox(height: Spacing.xs),
              Text(
                _riskStatement,
                style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
              const SizedBox(height: Spacing.md),
              SignaturePad(controller: _controller, label: 'Client signature'),
              const SizedBox(height: Spacing.md),
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) => FilledButton.icon(
                  onPressed: _controller.isEmpty ? null : () => unawaited(_save()),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Save the signature'),
                ),
              ),
            ],
          ),
        ),
      );
}

// ================================================================= the form

final class _GoodsInForm extends ConsumerStatefulWidget {
  const _GoodsInForm({super.key, required this.ctx});

  final GoodsInContext ctx;

  @override
  ConsumerState<_GoodsInForm> createState() => _GoodsInFormState();
}

class _GoodsInFormState extends ConsumerState<_GoodsInForm> {
  final TextEditingController _description = TextEditingController();
  final TextEditingController _receiptCode = TextEditingController();
  final TextEditingController _insurance = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final SignatureController _signature = SignatureController();

  late Money _declared = widget.ctx.zero;
  Stone? _stone;
  bool _riskAck = false;

  final List<Attachment> _photos = <Attachment>[];
  Attachment? _certificate;

  /// The file currently going up, for the footer's progress line.
  String? _uploading;

  GoodsInContext get _ctx => widget.ctx;

  @override
  void initState() {
    super.initState();
    _receiptCode.text = _ctx.suggestedCode;
    // One client-supplied line with no record yet is almost certainly the one at the counter, so
    // it is preselected and its description is offered as a starting point.
    final awaiting = _ctx.stonesAwaitingRecord;
    if (awaiting.length == 1) _selectStone(awaiting.single, seedDescription: true);
  }

  @override
  void dispose() {
    _description.dispose();
    _receiptCode.dispose();
    _insurance.dispose();
    _note.dispose();
    _signature.dispose();
    super.dispose();
  }

  void _selectStone(Stone? stone, {bool seedDescription = false}) {
    _stone = stone;
    if (stone == null) return;
    if (seedDescription || _description.text.trim().isEmpty) {
      _description.text = '${stone.displayTitle} — ${stone.gradeSummary}';
    }
    final declared = stone.declaredValue(_ctx.currency);
    if (declared != null && !declared.isZero) _declared = declared;
    final code = stone.receiptCode;
    if (code != null && code.trim().isNotEmpty) _receiptCode.text = code;
  }

  /// Convention 8: every missing piece named, in the order the counter fills them.
  String? get _blockReason {
    if (_description.text.trim().isEmpty) {
      return 'Describe what you are taking in — "1.52 ct oval, GIA 2185…, in the client’s ring '
          'box". This is the line a claim would be read against.';
    }
    if (_declared.isZero || _declared.isNegative) {
      return 'Enter the value the client declares. Custody with no declared value is neither '
          'insurable nor defensible.';
    }
    if (_receiptCode.text.trim().isEmpty) {
      return 'Enter the receipt number the client is walking out with. It is what they will '
          'quote when they ring.';
    }
    if (_ctx.verifierId == null) {
      return 'Your session has no user record, so nothing can be verified against your name. '
          'Sign in again.';
    }
    if (!_riskAck) {
      return 'Read the risk terms to the client and tick the acknowledgement together. Without '
          'it the goods are not accepted.';
    }
    return null;
  }

  /// Pressed for, not required. Stated separately from [_blockReason] so the operator can see the
  /// difference between "cannot record this" and "come back to this".
  List<String> get _softGaps => [
        if (_photos.isEmpty) 'condition photographs',
        if (_signature.isEmpty) 'the client’s signature',
        if (_insurance.text.trim().isEmpty) 'an insurance reference',
        if (_certificate == null) 'the certificate',
      ];

  Future<void> _addFile({required bool asCertificate}) async {
    final source = await pickVaultFileSource(
      context,
      title: asCertificate ? 'Attach the certificate' : 'Photograph the goods',
      blurb: asCertificate
          ? 'The lab report the client brought with the stone.'
          : 'Photograph the stone as it arrives, including any chips or damage that are already '
              'there.',
      allowFiles: true,
    );
    if (source == null || !mounted) return;

    try {
      final picked = await takeVaultFile(source);
      if (picked == null || !mounted) return;

      setState(() => _uploading = picked.filename);
      final attachment = await ref.read(attachmentStoreProvider).upload(
            UploadRequest.file(
              orgId: _ctx.job.orgId,
              // A condition photograph is valuation and evidence material, so it routes to the
              // internal `vault` bucket. The certificate is the client's own document and goes to
              // `job-files`, where the portal can show it back to them.
              kind: asCertificate
                  ? AttachmentKind.certificatePdf
                  : AttachmentKind.stonePhoto,
              file: picked.file,
              filename: picked.filename,
              jobId: _ctx.job.id,
              caption: asCertificate
                  ? 'Client certificate — ${_receiptCode.text.trim()}'
                  : 'Condition at hand-over — ${_receiptCode.text.trim()}',
            ),
          );
      if (!mounted) return;
      setState(() {
        _uploading = null;
        if (asCertificate) {
          _certificate = attachment;
        } else {
          _photos.add(attachment);
        }
      });
    } on DhFailure catch (failure) {
      if (!mounted) return;
      setState(() => _uploading = null);
      showFailure(context, failure);
    }
  }

  Future<void> _removeFile(Attachment file) async {
    final agreed = await confirmAction(
      context,
      title: 'Delete ${file.filename}?',
      message: 'The file is removed from the vault storage. If the goods are already at the '
          'counter, take the photograph again before recording the receipt.',
      confirmLabel: 'Delete the file',
      destructive: true,
    );
    if (!agreed || !mounted) return;
    try {
      await ref.read(attachmentStoreProvider).delete(file);
      if (!mounted) return;
      setState(() {
        _photos.removeWhere((a) => a.id == file.id);
        if (_certificate?.id == file.id) _certificate = null;
      });
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  /// The signature is rasterised and uploaded at the moment of recording, not while the client is
  /// still drawing — an upload per stroke would be absurd and a half-drawn name is not evidence.
  ///
  /// A failure here does **not** stop the receipt. The whole point of separating the four required
  /// facts from the evidence is that a client never leaves without a receipt because the shop
  /// Wi-Fi was slow; the signature is then one of the gaps the custody list chases. The failure is
  /// returned rather than thrown so the operator is told which half did not land.
  Future<({String? id, String? failure})> _uploadSignature() async {
    if (_signature.isEmpty) return (id: null, failure: null);
    final bytes = await _signature.toPng(
      pixelRatio: mounted ? MediaQuery.devicePixelRatioOf(context) : 3,
    );
    if (bytes == null || !mounted) return (id: null, failure: null);

    final code = _receiptCode.text.trim().replaceAll(RegExp('[^A-Za-z0-9-]'), '');
    setState(() => _uploading = 'signature-$code.png');
    try {
      final attachment = await ref.read(attachmentStoreProvider).upload(
            UploadRequest.bytes(
              orgId: _ctx.job.orgId,
              // Literally proof of delivery: the client delivered the goods to us, and they
              // should be able to see what they signed.
              kind: AttachmentKind.proofOfDelivery,
              filename: 'goods-in-$code.png',
              bytes: bytes,
              jobId: _ctx.job.id,
              caption: 'Client signature at goods-in — $code',
            ),
          );
      return (id: attachment.id, failure: null);
    } on DhFailure catch (failure) {
      return (id: null, failure: failure.message);
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }

  Future<void> _record() async {
    if (_blockReason != null) return;

    final agreed = await confirmAction(
      context,
      title: 'Take custody of ${_declared.format()} of client property?',
      message: 'Receipt ${_receiptCode.text.trim()} will be recorded against your name, at '
          '${_declared.format()}, and the workshop carries the goods until they are handed back.'
          '${_softGaps.isEmpty ? '' : ' You are still missing ${_softGaps.join(', ')} — the '
              'record can be completed afterwards, but an insurer asks for all of it.'}',
      confirmLabel: 'Take custody',
      cancelLabel: 'Not yet',
    );
    if (!agreed || !mounted) return;

    try {
      final signature = await _uploadSignature();
      if (!mounted) return;

      final receipt = await ref.read(inventoryActionsProvider.notifier).recordGoodsIn(
            jobId: _ctx.job.id,
            description: _description.text,
            declaredValue: _declared,
            riskAck: _riskAck,
            receiptCode: _receiptCode.text,
            customerId: _ctx.job.customerId,
            stoneId: _stone?.id,
            photoIds: [for (final file in _photos) file.id],
            certId: _certificate?.id,
            customerSigId: signature.id,
            insuranceRef: _insurance.text,
            note: _note.text,
          );
      if (!mounted) return;
      showDone(
        context,
        signature.failure == null
            ? 'Receipt ${receipt.receiptCode} recorded. ${receipt.declaredValue.format()} is in '
                'the workshop’s care.'
            : 'Receipt ${receipt.receiptCode} recorded, but the signature did not upload: '
                '${signature.failure} Add it from the custody list.',
      );
    } on DhFailure catch (failure) {
      if (!mounted) return;
      setState(() => _uploading = null);
      showFailure(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = ref.watch(inventoryActionsProvider) != null || _uploading != null;
    final blocked = _blockReason;
    final candidates = _ctx.stones;

    return DhSectionCard(
      title: 'Take goods in',
      subtitle: 'The record is complete or it is not made.',
      leading: const Icon(Icons.assignment_turned_in_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const VaultNote(
            tone: VaultNoteTone.risk,
            icon: Icons.warning_amber_rounded,
            text: 'You are taking a client’s property into the workshop. Until it is handed back '
                'or set into the finished piece, it is our responsibility.',
          ),
          const SizedBox(height: Spacing.md),

          // ------------------------------------------------------ stone line
          if (candidates.isNotEmpty) ...[
            const VaultHeading('Which stone line is this?'),
            const SizedBox(height: Spacing.sm),
            for (final stone in candidates) ...[
              SelectableTile(
                title: stone.displayTitle,
                blurb: stone.gradeSummary,
                icon: Icons.diamond_outlined,
                selected: _stone?.id == stone.id,
                inGroup: true,
                enabled: !busy,
                badge: stone.hasCustodyRecord
                    ? const StatusChip(
                        label: 'Already recorded',
                        tone: ChipTone.success,
                        dense: true,
                      )
                    : const StatusChip(
                        label: 'No record yet',
                        tone: ChipTone.danger,
                        dense: true,
                      ),
                onTap: () => setState(
                  () => _selectStone(_stone?.id == stone.id ? null : stone),
                ),
              ),
              const SizedBox(height: Spacing.sm),
            ],
            VaultNote(
              text: _stone == null
                  ? 'Tie the receipt to a stone line and the job’s own custody gate is satisfied '
                      'by this act. Leave it unset for anything else the client handed over.'
                  : 'The declared value, receipt code and acknowledgement will be written onto '
                      '${_stone!.displayTitle} as well as onto the receipt.',
            ),
            const SizedBox(height: Spacing.md),
          ],

          // ------------------------------------------------------ the four required facts
          TextField(
            controller: _description,
            enabled: !busy,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'What are you taking in?',
              alignLabelWithHint: true,
              hintText: '1.52 ct oval natural sapphire, GIA 2185674421, in a grey ring box',
              helperText: 'Describe it as an outsider would have to recognise it.',
            ),
          ),
          const SizedBox(height: Spacing.md),
          MoneyField(
            value: _declared,
            label: 'Declared value',
            enabled: !busy,
            // No currency selector on purpose: the job is priced in one currency and
            // `recordCustody` refuses a mismatch, because storing 4,850 paise as 4,850 cents is a
            // silent eighty-fold error on an insurance figure.
            currencies: [_ctx.currency],
            helperText: 'What the client says it is worth, in ${_ctx.currency}. Insurance cover '
                'is written against this figure — take it from a certificate or a valuation, not '
                'a guess.',
            onChanged: (value) => setState(() => _declared = value),
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _receiptCode,
            enabled: !busy,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [_UpperCase()],
            style: AppTheme.mono(size: 14),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Receipt number given to the client',
              hintText: _ctx.suggestedCode,
              helperText: 'Suggested from the last receipt on the books. The number on the paper '
                  'the client walks out with.',
            ),
          ),
          const SizedBox(height: Spacing.md),
          DhCard(
            tone: DhCardTone.inset,
            child: DataPairGrid(
              children: [
                DataPair.mono(
                  label: 'Verified by',
                  // D-008: the session user, never a typed name. A custody record naming someone
                  // who was not signed in is worth nothing.
                  value: _ctx.verifierName ?? 'Not signed in',
                  icon: Icons.person_outline_rounded,
                ),
                DataPair.timestamp(label: 'Taken in at', utc: DateTime.now().toUtc()),
              ],
            ),
          ),
          const SizedBox(height: Spacing.md),
          ToggleTile(
            title: 'The client has accepted the risk terms',
            blurb: _riskStatement,
            value: _riskAck,
            enabled: !busy,
            tone: VaultNoteTone.risk,
            onChanged: (value) => setState(() => _riskAck = value),
          ),
          const SizedBox(height: Spacing.lg),

          // ------------------------------------------------------ evidence
          const VaultHeading('Evidence'),
          const SizedBox(height: Spacing.sm),
          Text(
            'Not required to make the receipt — a client should never leave without one because a '
            'camera was slow — but this is exactly what an insurer asks for.',
            style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.sm),
          AttachmentGrid(
            items: [
              for (final file in _photos)
                AttachmentView(
                  id: file.id,
                  kind: file.kind,
                  filename: file.filename,
                  meta: file.metaLabel,
                ),
            ],
            onAdd: busy ? null : () => unawaited(_addFile(asCertificate: false)),
            addLabel: 'Condition photo',
            addIcon: Icons.add_a_photo_outlined,
            onDelete: busy ? null : (view) => unawaited(_removeById(view.id)),
          ),
          const SizedBox(height: Spacing.md),
          if (_certificate == null)
            OutlinedButton.icon(
              onPressed: busy ? null : () => unawaited(_addFile(asCertificate: true)),
              icon: const Icon(Icons.description_outlined, size: 18),
              label: const Text('Attach the certificate'),
            )
          else
            AttachmentTile.row(
              item: AttachmentView(
                id: _certificate!.id,
                kind: _certificate!.kind,
                filename: _certificate!.filename,
                meta: _certificate!.metaLabel,
              ),
              onDelete: busy ? null : () => unawaited(_removeFile(_certificate!)),
            ),
          const SizedBox(height: Spacing.md),
          SignaturePad(
            controller: _signature,
            enabled: !busy,
            label: 'Client signature',
            hint: 'Ask the client to sign for the goods',
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _insurance,
            enabled: !busy,
            style: AppTheme.mono(size: 14),
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Insurance reference (optional)',
              hintText: 'POL-4471 / endorsement 12',
              helperText: 'The policy or endorsement this value sits under.',
            ),
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _note,
            enabled: !busy,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              alignLabelWithHint: true,
              hintText: 'Client mentioned an existing chip on the girdle.',
            ),
          ),
          const SizedBox(height: Spacing.lg),

          // ------------------------------------------------------ the act
          // Listened to rather than read: the soft-gap line mentions the signature, and the pad
          // is a ChangeNotifier, so this is the one block that has to follow the client's pen.
          ListenableBuilder(
            listenable: _signature,
            builder: (context, _) {
              if (blocked != null) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  child: VaultNote(
                    tone: VaultNoteTone.risk,
                    icon: Icons.lock_outline_rounded,
                    text: blocked,
                  ),
                );
              }
              final gaps = _softGaps;
              if (gaps.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: VaultNote(
                  tone: VaultNoteTone.consequence,
                  icon: Icons.fact_check_outlined,
                  text: 'You can record this now without ${gaps.join(', ')}, and add them from '
                      'the custody list above. The receipt itself is complete.',
                ),
              );
            },
          ),
          if (_uploading != null) ...[
            Row(
              children: [
                const VaultSpinner(size: 14),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    'Uploading ${_uploading!}',
                    style: AppTheme.mono(size: 11, color: context.scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.sm),
          ],
          FilledButton.icon(
            // A real gate: a null handler, never a painted-disabled button that still fires.
            onPressed: blocked == null && !busy ? () => unawaited(_record()) : null,
            icon: busy
                ? const VaultSpinner()
                : const Icon(Icons.assignment_turned_in_outlined),
            label: Text(
              _declared.isZero
                  ? 'Take custody'
                  : 'Take custody of ${_declared.format(compact: true)}',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _removeById(String attachmentId) async {
    for (final file in _photos) {
      if (file.id == attachmentId) {
        await _removeFile(file);
        return;
      }
    }
  }
}

/// A receipt number is an identifier: it is stored, quoted on the phone and compared, so it is
/// upper-cased as it is typed rather than tidied up later.
final class _UpperCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue value) =>
      TextEditingValue(text: value.text.toUpperCase(), selection: value.selection);
}
