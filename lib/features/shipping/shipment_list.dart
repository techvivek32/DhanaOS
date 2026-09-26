/// Every leg of one job — the screen behind `/shipping/<jobId>`.
///
/// This is the correction the corpus most needed in its logistics half. `shipping_dispatch`
/// modelled **one** shipment per job while the same 46 files showed four movements on one job: a
/// wax "en route from Central Hub", a to-lab leg carrying "FEDEX: 9876543210", the lab's return,
/// and then the final insured dispatch. Three of those four had nowhere to be recorded, so the
/// only movement the system knew about was the last one.
///
/// So the job's shipping surface is a list, not a form. Each row is a real movement with its own
/// courier, waybill, declared value and protocol; the final dispatch is simply the last of them,
/// and it is the one the tax invoice hangs off (D-004).
///
/// Wire it into the router by replacing the `/shipping/:jobId` placeholder with
/// `ShipmentListScreen(jobId: state.pathParameters['jobId']!)`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/billing/invoice_screen.dart';
import 'package:dhanaos/features/billing/payment_screen.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/shipping/shipment_screen.dart';
import 'package:dhanaos/features/shipping/shipping_actions.dart';
import 'package:dhanaos/features/shipping/shipping_gateway.dart';
import 'package:dhanaos/features/shipping/shipping_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

final class ShipmentListScreen extends ConsumerWidget {
  const ShipmentListScreen({super.key, required this.jobId});

  final String jobId;

  /// Open the shipping surface from a job detail, keeping the operator's place behind them.
  static Future<void> push(BuildContext context, String jobId) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ShipmentListScreen(jobId: jobId)),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(shippingBundleProvider(jobId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shipments'),
        actions: [
          IconButton(
            onPressed: () => ref.invalidate(shippingBundleProvider(jobId)),
            tooltip: 'Re-read every leg',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoadingSkeleton(height: 64),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.list(count: 3),
            ],
          ),
        ),
        error: (error, _) => ErrorState(
          title: 'The shipping legs did not load',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read this job\'s shipments. Check the connection and try '
                  'again.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(shippingBundleProvider(jobId)),
        ),
        data: (bundle) => _Loaded(bundle: bundle),
      ),
    );
  }
}

final class _Loaded extends ConsumerWidget {
  const _Loaded({required this.bundle});

  final ShippingBundle bundle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = bundle.job;
    final legs = bundle.legs;
    final busy = ref.watch(shippingActionsProvider) != null;
    final permissions = ref.watch(permissionsProvider);
    // An engineer or production manager can prepare a leg; only logistics and admin may press
    // dispatch. The route already fences the area — this decides what the buttons do inside it.
    final canPrepare = permissions.canDispatch || permissions.canEditJob;

    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.refresh(shippingBundleProvider(job.id).future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.md,
                Spacing.md,
                Spacing.xl,
              ),
              children: [
                _JobHeader(bundle: bundle),
                if (bundle.rail.isSeeded) ...[
                  const SizedBox(height: Spacing.md),
                  JobStageRail.compact(nodes: _railNodes(bundle)),
                ],
                const SizedBox(height: Spacing.md),
                _BillingStrip(bundle: bundle),
                const SizedBox(height: Spacing.lg),
                SectionHeading(title: 'Legs', count: legs.length),
                const SizedBox(height: Spacing.sm + Spacing.xs),
                if (bundle.legsAwaitingProtocol > 0) ...[
                  AdviceNote(
                    tone: AdviceTone.consequence,
                    text: '${bundle.legsAwaitingProtocol} leg'
                        '${bundle.legsAwaitingProtocol == 1 ? '' : 's'} cannot be dispatched '
                        'yet — the security protocol is unfinished. Dispatch is refused while '
                        'any step is outstanding.',
                  ),
                  const SizedBox(height: Spacing.sm + Spacing.xs),
                ],
                if (legs.isEmpty)
                  EmptyState(
                    compact: true,
                    icon: Icons.local_shipping_outlined,
                    title: 'No legs opened yet',
                    message: 'A job usually travels several times — out to the caster, back, out '
                        'to the lab, back, then out to the customer. Open a leg for the next '
                        'movement.',
                    actionLabel: canPrepare ? 'Open a leg' : null,
                    onAction: canPrepare && !busy
                        ? () => unawaited(_openLeg(context, ref))
                        : null,
                  )
                else
                  for (final shipment in legs) ...[
                    _LegCard(
                      view: ShipmentLegView(bundle: bundle, shipment: shipment),
                      onOpen: () => unawaited(
                        ShipmentScreen.push(context, jobId: job.id, shipmentId: shipment.id),
                      ),
                    ),
                    const SizedBox(height: Spacing.sm + Spacing.xs),
                  ],
              ],
            ),
          ),
        ),
        StickyActions(
          note: canPrepare
              ? null
              : 'Only Logistics, Production Manager or Engineer can open a leg on this job.',
          children: [
            FilledButton.icon(
              onPressed: canPrepare && !busy ? () => unawaited(_openLeg(context, ref)) : null,
              icon: const Icon(Icons.add_road_rounded, size: 18),
              label: const Text('Open a leg'),
            ),
          ],
        ),
      ],
    );
  }

  List<StageNode> _railNodes(ShippingBundle bundle) => [
        for (final row in bundle.rail.stages)
          StageNode(
            stage: row.stage,
            state: row.state,
            detail: row.isActive ? row.dwellLabel : null,
            isLate: row.isLate,
            withPartner: row.isWithPartner,
          ),
      ];

  /// Pick the movement, open the draft leg, then land the operator on it. Courier, value, routing
  /// and the protocol all belong to the leg screen — one place that owns the detail.
  Future<void> _openLeg(BuildContext context, WidgetRef ref) async {
    final leg = await _pickLeg(context, bundle);
    if (leg == null || !context.mounted) return;

    try {
      final created = await ref.read(shippingActionsProvider.notifier).openLeg(
            jobId: bundle.job.id,
            leg: leg,
            declaredValue:
                leg == ShipmentLeg.finalDispatch ? bundle.suggestedDeclaredValue : null,
          );
      if (!context.mounted) return;
      showDone(context, '${leg.label} leg opened. Fill in the courier and work the protocol.');
      await ShipmentScreen.push(
        context,
        jobId: bundle.job.id,
        shipmentId: created.id,
      );
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }
}

// ================================================================= header

final class _JobHeader extends StatelessWidget {
  const _JobHeader({required this.bundle});

  final ShippingBundle bundle;

  @override
  Widget build(BuildContext context) {
    final job = bundle.job;
    final customer = bundle.customer;

    return DhCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusChip.code(job.displayCode),
              const SizedBox(width: Spacing.sm),
              PriorityChip(job.priority, showStandard: false),
              const Spacer(),
              StatusChip.job(job.status, dense: true),
            ],
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          Text(job.displayTitle, style: context.text.headlineSmall),
          if (customer != null) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              customer.displayName,
              style: context.text.bodyMedium
                  ?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
          ],
          if (bundle.suggestedDeclaredValue != null) ...[
            const SizedBox(height: Spacing.md),
            DataPair.money(
              label: 'Approved value',
              amount: bundle.suggestedDeclaredValue!,
              tooltip: 'From the approved quote. Every leg should be declared at this figure.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= billing strip

/// D-004 on the shipping screen, because that is where it bites.
///
/// The corpus ended at "Confirm Dispatch" and had no invoice at all. An Indian manufacturer
/// cannot legally ship without a tax invoice, so the fact is stated here — next to the button
/// that sends the package — rather than left to a finance screen nobody on the packing bench
/// opens.
final class _BillingStrip extends ConsumerWidget {
  const _BillingStrip({required this.bundle});

  final ShippingBundle bundle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobId = bundle.job.id;
    final invoice = bundle.issuedInvoice ?? bundle.latestInvoice;
    final advice = bundle.invoiceAdvice;

    if (invoice == null) {
      return AdviceNote(
        tone: AdviceTone.risk,
        text: advice ?? 'No tax invoice has been raised for this job.',
        action: FilledButton(
          onPressed: () => unawaited(InvoiceScreen.push(context, jobId: jobId)),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 36)),
          child: const Text('Raise it'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (advice != null) ...[
          AdviceNote(tone: AdviceTone.risk, text: advice),
          const SizedBox(height: Spacing.sm + Spacing.xs),
        ],
        DhSectionCard(
          title: 'Tax invoice',
          leading: const Icon(Icons.receipt_long_outlined),
          action: invoice.isIssued
              ? StatusChip(
                  label: invoice.isPaid
                      ? 'Paid'
                      : invoice.isPartlyPaid
                          ? 'Part paid'
                          : 'Unpaid',
                  dense: true,
                  tone: invoice.isPaid
                      ? ChipTone.success
                      : invoice.isPartlyPaid
                          ? ChipTone.warning
                          : ChipTone.neutral,
                )
              : const StatusChip(label: 'Draft', dense: true),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DataPairGrid(
                children: [
                  DataPair.mono(label: 'Number', value: invoice.invoiceNo),
                  DataPair.timestamp(
                    label: 'Date',
                    utc: invoice.invoiceDate,
                    withTime: false,
                  ),
                  DataPair.money(label: 'Total', amount: invoice.grandTotal),
                  DataPair.money(
                    label: 'Outstanding',
                    amount: invoice.amountDue,
                    valueColor: invoice.amountDue.isZero
                        ? context.dh.success
                        : context.scheme.onSurface,
                  ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => unawaited(
                        InvoiceScreen.push(
                          context,
                          jobId: jobId,
                          invoiceId: invoice.id,
                        ),
                      ),
                      icon: const Icon(Icons.description_outlined, size: 18),
                      label: const Text('Invoice'),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: invoice.isIssued
                          ? () => unawaited(
                                PaymentScreen.push(
                                  context,
                                  jobId: jobId,
                                  invoiceId: invoice.id,
                                ),
                              )
                          : null,
                      icon: const Icon(Icons.payments_outlined, size: 18),
                      label: const Text('Payments'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ================================================================= leg card

final class _LegCard extends StatelessWidget {
  const _LegCard({required this.view, required this.onOpen});

  final ShipmentLegView view;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final shipment = view.shipment;
    final scheme = context.scheme;
    final dh = context.dh;
    final warning = view.warnings.isEmpty ? null : view.warnings.first;

    return DhCard(
      onTap: onOpen,
      accent: shipment.isDelivered
          ? dh.success
          : shipment.status.isInFlight
              ? scheme.secondary
              : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(shipmentLegIcon(shipment.leg), size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  shipment.leg.label,
                  style: context.text.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ShipmentStatusChip(shipment.status, dense: true),
            ],
          ),
          const SizedBox(height: Spacing.md),
          DataPairGrid(
            children: [
              DataPair(
                label: 'Courier',
                value: shipment.courier == null ? '' : shipment.courierLabel,
              ),
              DataPair.mono(
                label: 'Waybill',
                value: shipment.waybill ?? '',
              ),
              if (shipment.declaredValue != null)
                DataPair.money(
                  label: 'Declared',
                  amount: shipment.declaredValue!,
                  emphasis: DataEmphasis.normal,
                  valueColor: view.declaredValueUnderQuote ? dh.goldText : null,
                ),
              DataPair.custom(
                label: 'Protocol',
                child: StatusChip(
                  label: shipment.checkProgressLabel,
                  mono: true,
                  dense: true,
                  tone: shipment.isSecurityComplete ? ChipTone.success : ChipTone.warning,
                ),
              ),
              if (view.counterparty != null)
                DataPair(
                  label: view.isInbound ? 'From' : 'To',
                  value: view.counterparty!.name,
                ),
              if (shipment.isInternational)
                DataPair.custom(
                  label: 'Customs',
                  child: StatusChip(
                    label: shipment.needsCustomsPaperwork ? 'Incomplete' : 'Ready',
                    dense: true,
                    tone: shipment.needsCustomsPaperwork
                        ? ChipTone.danger
                        : ChipTone.success,
                  ),
                ),
            ],
          ),
          if (shipment.dispatchedAt != null || shipment.deliveredAt != null) ...[
            const SizedBox(height: Spacing.md),
            Text(
              [
                if (shipment.dispatchedAt != null)
                  'Out ${localTimestamp(shipment.dispatchedAt!)}',
                if (shipment.deliveredAt != null)
                  '${view.isInbound ? 'Received' : 'Delivered'} '
                      '${localTimestamp(shipment.deliveredAt!)}',
                if (shipment.transitTime != null && !shipment.isDelivered)
                  '${shortSpan(shipment.transitTime!)} in transit',
              ].join('  ·  '),
              style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
            ),
          ],
          if (warning != null) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            AdviceNote(tone: AdviceTone.risk, text: warning),
          ],
        ],
      ),
    );
  }
}

// ================================================================= leg picker

/// Which movement to open.
///
/// Legs that already have an unsettled row are still offered — a lab rejection means a second
/// to-lab leg is a real thing — but the tile says so, because opening a duplicate by accident
/// splits one movement's protocol across two rows.
Future<ShipmentLeg?> _pickLeg(BuildContext context, ShippingBundle bundle) =>
    showModalBottomSheet<ShipmentLeg>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Open a leg', style: sheetContext.text.headlineSmall),
              const SizedBox(height: Spacing.xs),
              Text(
                'One row per movement. The piece travels several times before it reaches the '
                'customer, and each journey carries its own courier, value and seals.',
                style: sheetContext.text.bodyMedium
                    ?.copyWith(color: sheetContext.scheme.onSurfaceVariant),
              ),
              const SizedBox(height: Spacing.md),
              SelectableTileGroup<ShipmentLeg>(
                values: ShipmentLeg.values,
                selected: null,
                labelOf: (leg) => leg.label,
                blurbOf: shipmentLegBlurb,
                iconOf: shipmentLegIcon,
                badgeOf: (leg) {
                  final open = bundle.openLegOf(leg);
                  if (open != null) {
                    return StatusChip(
                      label: open.status.label,
                      dense: true,
                      tone: ChipTone.warning,
                    );
                  }
                  final done = bundle.legsOf(leg).length;
                  return done == 0
                      ? null
                      : StatusChip(
                          label: '$done done',
                          dense: true,
                          tone: ChipTone.success,
                        );
                },
                onChanged: (leg) => Navigator.of(sheetContext).pop(leg),
              ),
              const SizedBox(height: Spacing.sm),
              TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      ),
    );
