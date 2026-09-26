/// Everything waiting on the client: the design, the wax and the price.
///
/// **This screen is the one the corpus most needed and least had.** `pricing_approval` showed a
/// `$4,850` total, a five-line breakdown and exactly one button — "Approve". There was no
/// rejection, no counter-offer and nowhere to put a number, which means a client who thought the
/// price was wrong had no move inside the product at all. D-006 restores all three exits, and
/// D-011 rule 2's asymmetry governs every one of them: **approving takes one tap; sending
/// something back requires a sentence.**
///
/// Three decisions, three different records:
///
///  * **Design** — a `cad_reviews` row, the same table and the same
///    `cad_reject_needs_comment` CHECK the internal reviewer writes through. A customer really can
///    insert one: the job-scoped write policy evaluates only `with check` on an INSERT.
///  * **Wax** — an immutable `activity_events` entry. There is no `wax_reviews` table and there
///    should not be: this is a client saying yes to a physical object, and the audit trail is the
///    record that matters. The gate appears only where `acceptance_criteria.authority = 'customer'`
///    — the option `quality_acceptance` offered and never wired.
///  * **Price** — the audit entry plus the quote transition, with the transition verified rather
///    than assumed. See [PortalActions.decidePrice] for why that verification exists.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/portal/portal_actions.dart';
import 'package:dhanaos/features/portal/portal_gateway.dart';
import 'package:dhanaos/features/portal/portal_surface.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class PortalApprovalsScreen extends ConsumerWidget {
  const PortalApprovalsScreen({super.key});

  /// Pushed rather than routed: deciding is a task inside the portal and belongs on the stack
  /// above whatever the client was reading.
  static Future<void> push(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const PortalApprovalsScreen()),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(portalApprovalsProvider);

    return ClientSurface(
      child: Scaffold(
        appBar: AppBar(title: const Text('Your approvals')),
        body: async.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(Spacing.md),
            child: LoadingSkeleton.list(count: 3),
          ),
          error: (error, _) => ErrorState(
            title: 'Your approvals did not load',
            message: error is DhFailure
                ? error.message
                : 'DhanaOS could not reach the workshop just now. Try again in a moment.',
            detail: error is DhFailure ? error.detail : error.toString(),
            onRetry: () => ref.invalidate(portalApprovalsProvider),
          ),
          data: (approvals) => _Body(approvals: approvals),
        ),
      ),
    );
  }
}

final class _Body extends ConsumerWidget {
  const _Body({required this.approvals});

  final PortalApprovals approvals;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outstanding = approvals.outstanding;
    final settled = approvals.settled;

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(portalApprovalsProvider),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xxl),
        children: [
          if (outstanding.isEmpty)
            const EmptyState(
              icon: Icons.task_alt_rounded,
              title: 'Nothing is waiting on you',
              message: 'When the workshop needs your approval on a drawing, a wax model or a '
                  'price, it appears here and the piece waits until you decide.',
            )
          else ...[
            PortalNote(
              tone: PortalNoteTone.action,
              icon: Icons.pending_actions_outlined,
              text: outstanding.length == 1
                  ? 'One decision is holding a piece where it is.'
                  : '${outstanding.length} decisions are holding pieces where they are.',
            ),
            const SizedBox(height: Spacing.md),
            for (final item in outstanding) ...[
              _DecisionCard(item: item),
              const SizedBox(height: Spacing.md),
            ],
          ],
          if (settled.isNotEmpty) ...[
            const SizedBox(height: Spacing.lg),
            SectionHeading(title: 'Already decided', count: settled.length),
            const SizedBox(height: Spacing.sm + Spacing.xs),
            for (final item in settled) ...[
              _SettledCard(item: item),
              const SizedBox(height: Spacing.sm),
            ],
          ],
        ],
      ),
    );
  }
}

// ================================================================= one decision

final class _DecisionCard extends ConsumerWidget {
  const _DecisionCard({required this.item});

  final PortalApprovalItem item;

  static final _asked = DateFormat('d MMM yyyy');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dh = context.dh;
    final askedAt = item.askedAt;

    return DhCard(
      accent: dh.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OrderLine(
            code: item.job.displayCode,
            title: item.job.displayTitle,
            trailing: DecisionChip(item, dense: true),
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          Row(
            children: [
              StatusChip(label: item.kind.label, tone: ChipTone.accent, dense: true),
              const SizedBox(width: Spacing.sm),
              StatusChip.code(item.subjectLabel, dense: true),
              if (askedAt != null) ...[
                const SizedBox(width: Spacing.sm),
                Flexible(
                  child: Text(
                    'Sent ${_asked.format(askedAt.toLocal())}',
                    style: context.text.bodySmall
                        ?.copyWith(color: context.scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: Spacing.md),
          switch (item.kind) {
            PortalDecisionKind.design => _DesignBody(item: item),
            PortalDecisionKind.wax => _WaxBody(item: item),
            PortalDecisionKind.price => _PriceBody(item: item),
          },
        ],
      ),
    );
  }
}

// ================================================================= design

final class _DesignBody extends ConsumerWidget {
  const _DesignBody({required this.item});

  final PortalApprovalItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final revision = item.revision!;
    final note = revision.designerNote?.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (item.renders.isNotEmpty) ...[
          AttachmentGrid(
            items: [
              for (final render in item.renders)
                AttachmentView(
                  id: render.id,
                  kind: render.kind,
                  filename: render.filename,
                  meta: render.metaLabel,
                  thumbnail: _thumb(item.renderUrls[render.id]),
                ),
            ],
          ),
          const SizedBox(height: Spacing.md),
        ] else ...[
          const PortalNote(
            icon: Icons.image_not_supported_outlined,
            text: 'The workshop has not attached a render to this version yet. Ask them for one '
                'before you approve it.',
          ),
          const SizedBox(height: Spacing.md),
        ],
        if (note != null && note.isNotEmpty) ...[
          DataPair(label: 'From the designer', value: note, maxLines: 6),
          const SizedBox(height: Spacing.md),
        ],
        _DecisionButtons(
          item: item,
          // D-011 rule 2: approval is free, refusal owes the designer a reason.
          approveLabel: item.kind.approveLabel,
          refuseLabel: item.kind.refuseLabel,
          task: PortalTask.design,
        ),
      ],
    );
  }

  static ImageProvider? _thumb(String? url) =>
      url == null || url.isEmpty ? null : NetworkImage(url);
}

// ================================================================= wax

final class _WaxBody extends StatelessWidget {
  const _WaxBody({required this.item});

  final PortalApprovalItem item;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PortalNote(
          icon: Icons.pan_tool_outlined,
          text: 'The wax is the shape your piece is cast from. Once it is poured, changing the '
              'form means starting the metal again — so this is the last easy moment to move '
              'anything.',
        ),
        const SizedBox(height: Spacing.md),
        _DecisionButtons(
          item: item,
          approveLabel: item.kind.approveLabel,
          refuseLabel: item.kind.refuseLabel,
          task: PortalTask.wax,
        ),
      ],
    );
  }
}

// ================================================================= price

/// D-003's five customer-facing categories, and the three exits `pricing_approval` reduced to one.
final class _PriceBody extends ConsumerWidget {
  const _PriceBody({required this.item});

  final PortalApprovalItem item;

  /// Convention 7: `valid_until` is a calendar day and renders as one.
  static final _held = DateFormat('d MMM yyyy');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quote = item.quote!;
    final scheme = context.scheme;
    final byCategory = quote.byCategory;
    final busy = ref.watch(portalActionsProvider) != null;
    final running = ref.watch(portalActionsProvider) == PortalTask.price;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DhCard(
          tone: DhCardTone.inset,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The five categories a customer actually approves (D-003). The commercial screen's
              // four internal lines — CAD Design, Setting, Finishing & Polish, Certification —
              // roll up into these; they are cost accounting, not a quotation.
              for (final category in CostCategory.values) ...[
                _CostRow(label: category.label, amount: byCategory[category]!),
                const SizedBox(height: Spacing.sm),
              ],
              Divider(height: Spacing.md, color: context.dh.outlineVariant),
              _CostRow(label: 'Subtotal', amount: quote.subtotal),
              const SizedBox(height: Spacing.sm),
              // D-004: an Indian manufacturer cannot legally ship without a tax invoice, so tax
              // is a line the client sees rather than a surprise at delivery.
              _CostRow(label: 'GST', amount: quote.taxTotal),
              const SizedBox(height: Spacing.sm + Spacing.xs),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'TOTAL',
                      style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  Text(
                    quote.grandTotal.format(),
                    style: AppTheme.mono(
                      size: 20,
                      weight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (quote.validUntil != null) ...[
          const SizedBox(height: Spacing.sm + Spacing.xs),
          PortalNote(
            tone: quote.isExpired ? PortalNoteTone.risk : PortalNoteTone.calm,
            icon: Icons.schedule_outlined,
            text: quote.isExpired
                ? 'This quote lapsed on ${_held.format(quote.validUntil!.toLocal())}. Metal rates '
                    'move, so ask the workshop to re-issue it.'
                : 'Held until ${_held.format(quote.validUntil!.toLocal())}.',
          ),
        ],
        const SizedBox(height: Spacing.md),
        FilledButton.icon(
          onPressed: busy ? null : () => unawaited(_decide(context, ref, PriceVerdict.approve)),
          icon: running
              ? const PortalSpinner()
              : const Icon(Icons.check_rounded, size: 18),
          label: Text('${PriceVerdict.approve.label} — ${quote.grandTotal.format()}'),
        ),
        const SizedBox(height: Spacing.sm),
        // D-006: the two exits the mockup did not have. They are not hidden behind a menu —
        // a negotiation the product cannot express is a negotiation that happens over the phone
        // and never reaches the record.
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    busy ? null : () => unawaited(_decide(context, ref, PriceVerdict.counter)),
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: const Text('Counter-offer'),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    busy ? null : () => unawaited(_decide(context, ref, PriceVerdict.refuse)),
                icon: const Icon(Icons.close_rounded, size: 18),
                label: const Text('Refuse'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _decide(BuildContext context, WidgetRef ref, PriceVerdict verdict) async {
    final quote = item.quote!;
    _PriceAnswer? answer;

    if (verdict.isApproval) {
      final agreed = await confirmAction(
        context,
        title: 'Approve ${quote.grandTotal.format()}?',
        message: 'This is the figure the workshop invoices against, and it is recorded against '
            'your account. You can add a note if you want one on the record.',
        confirmLabel: 'Yes, approve it',
        cancelLabel: 'Not yet',
      );
      if (!agreed) return;
      answer = const _PriceAnswer();
    } else {
      if (!context.mounted) return;
      answer = await _PriceReplySheet.show(context, quote: quote, verdict: verdict);
    }
    if (answer == null || !context.mounted) return;

    try {
      final outcome = await ref.read(portalActionsProvider.notifier).decidePrice(
            item: item,
            verdict: verdict,
            counterAmount: answer.amount,
            reason: answer.reason,
          );
      if (!context.mounted) return;
      showDone(context, outcome.message('Quote v${quote.version}'));
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }
}

final class _CostRow extends StatelessWidget {
  const _CostRow({required this.label, required this.amount});

  final String label;
  final Money amount;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Text(
          amount.format(),
          // Convention 5: money is data, so it reads down a column.
          style: AppTheme.mono(size: 13.5, color: scheme.onSurface),
        ),
      ],
    );
  }
}

// ================================================================= approve / send back

/// The two-button pair every non-price decision ends with.
///
/// D-011 rule 2 in its customer-facing form: the approve button fires straight into a confirm,
/// while "ask for changes" opens a sheet that will not submit until something is typed.
final class _DecisionButtons extends ConsumerWidget {
  const _DecisionButtons({
    required this.item,
    required this.approveLabel,
    required this.refuseLabel,
    required this.task,
  });

  final PortalApprovalItem item;
  final String approveLabel;
  final String refuseLabel;
  final PortalTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(portalActionsProvider) != null;
    final running = ref.watch(portalActionsProvider) == task;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: busy ? null : () => unawaited(_decide(context, ref, approved: true)),
          icon: running ? const PortalSpinner() : const Icon(Icons.check_rounded, size: 18),
          label: Text(approveLabel),
        ),
        const SizedBox(height: Spacing.sm),
        OutlinedButton.icon(
          onPressed: busy ? null : () => unawaited(_decide(context, ref, approved: false)),
          icon: const Icon(Icons.edit_note_outlined, size: 18),
          label: Text(refuseLabel),
        ),
      ],
    );
  }

  Future<void> _decide(
    BuildContext context,
    WidgetRef ref, {
    required bool approved,
  }) async {
    String? comment;

    if (approved) {
      final agreed = await confirmAction(
        context,
        title: '${item.kind.approveLabel}?',
        message: item.kind == PortalDecisionKind.design
            ? 'The workshop takes this drawing as the agreed design and starts making from it. '
                'Later changes mean a new version.'
            : 'The workshop casts from this wax. Once the metal is poured, changing the form '
                'means starting again.',
        confirmLabel: 'Yes, approve it',
        cancelLabel: 'Not yet',
      );
      if (!agreed) return;
    } else {
      if (!context.mounted) return;
      comment = await promptForText(
        context,
        title: item.kind.refuseLabel,
        message: 'Tell the workshop what to change. This is the only thing they have to work '
            'from, so be as specific as you can.',
        fieldLabel: 'What needs to change',
        submitLabel: 'Send it back',
        hint: item.kind == PortalDecisionKind.design
            ? 'The halo sits too high, and the band should be 2mm rather than 2.5mm.'
            : 'The shoulders are heavier than the drawing.',
      );
      // Backing out of the sheet is not a decision and owes the client no message.
      if (comment == null) return;
    }
    if (!context.mounted) return;

    try {
      final outcome = switch (item.kind) {
        PortalDecisionKind.design => await ref.read(portalActionsProvider.notifier).decideDesign(
              item: item,
              approved: approved,
              comment: comment,
            ),
        PortalDecisionKind.wax => await ref.read(portalActionsProvider.notifier).decideWax(
              item: item,
              approved: approved,
              comment: comment,
            ),
        // The price path has its own sheet and never reaches this pair.
        PortalDecisionKind.price => throw const RuleViolation(
            message: 'A price is decided from the quote itself.',
            code: 'portal_wrong_decision_path',
          ),
      };
      if (!context.mounted) return;
      showDone(context, outcome.message(item.subjectLabel));
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }
}

// ================================================================= the price sheet

/// What the client said about the price.
final class _PriceAnswer {
  const _PriceAnswer({this.amount, this.reason});

  final Money? amount;
  final String? reason;
}

/// The counter-offer and refusal sheet.
///
/// The counter figure is a [MoneyField] in the quote's own currency (D-004 — minor units, never a
/// double, and never a second currency on one quote). Submit stays shut until the reason is there,
/// because a number with no reasoning cannot be negotiated against.
final class _PriceReplySheet extends StatefulWidget {
  const _PriceReplySheet({required this.quote, required this.verdict});

  final Quote quote;
  final PriceVerdict verdict;

  static Future<_PriceAnswer?> show(
    BuildContext context, {
    required Quote quote,
    required PriceVerdict verdict,
  }) =>
      showModalBottomSheet<_PriceAnswer>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _PriceReplySheet(quote: quote, verdict: verdict),
      );

  @override
  State<_PriceReplySheet> createState() => _PriceReplySheetState();
}

class _PriceReplySheetState extends State<_PriceReplySheet> {
  late Money _offer = Money(widget.quote.grandTotalMinor, widget.quote.currency);
  final TextEditingController _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reason.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _reason
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  bool get _ready {
    if (_reason.text.trim().isEmpty) return false;
    if (!widget.verdict.needsAmount) return true;
    // An "offer" identical to the quote is not a counter-offer, and a zero is not a price.
    return _offer.minor > 0 && _offer.minor != widget.quote.grandTotalMinor;
  }

  String? get _amountError {
    if (!widget.verdict.needsAmount || _offer.minor <= 0) return null;
    if (_offer.minor == widget.quote.grandTotalMinor) {
      return 'That is the quoted figure. Approve it instead, or offer a different number.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final counter = widget.verdict.needsAmount;

    return Padding(
      padding: EdgeInsets.only(
        left: Spacing.md,
        right: Spacing.md,
        top: Spacing.md,
        // Keeps the fields above the keyboard on a phone.
        bottom: MediaQuery.viewInsetsOf(context).bottom + Spacing.md,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.verdict.label,
              style: context.text.headlineSmall?.copyWith(color: context.scheme.onSurface),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              widget.verdict.blurb,
              style: context.text.bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.md),
            DataPair.money(
              label: 'Quoted',
              amount: widget.quote.grandTotal,
              emphasis: DataEmphasis.strong,
            ),
            const SizedBox(height: Spacing.md),
            if (counter) ...[
              MoneyField(
                value: _offer,
                onChanged: (value) => setState(() => _offer = value),
                label: 'Your offer',
                // One quote, one currency (D-004). The selector is not offered.
                currencies: <String>[widget.quote.currency],
                errorText: _amountError,
                helperText: 'In ${widget.quote.currency}, the same currency as the quote.',
                autofocus: true,
              ),
              const SizedBox(height: Spacing.md),
            ],
            TextField(
              controller: _reason,
              minLines: 3,
              maxLines: 6,
              autofocus: !counter,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: counter ? 'What the offer is based on' : 'Why you are refusing it',
                hintText: counter
                    ? 'Our customer has a ceiling at this figure, and the certification line '
                        'can come out.'
                    : 'The metal line is well above what we were told at intake.',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: Spacing.md),
            FilledButton(
              onPressed: _ready
                  ? () => Navigator.of(context).pop(
                        _PriceAnswer(
                          amount: counter ? _offer : null,
                          reason: _reason.text.trim(),
                        ),
                      )
                  : null,
              child: Text(counter ? 'Send the counter-offer' : 'Send the refusal'),
            ),
            if (!_ready) ...[
              const SizedBox(height: Spacing.sm),
              const PortalNote(
                icon: Icons.edit_outlined,
                text: 'Write the reason first. Without it nobody at the workshop can re-quote '
                    'the job.',
              ),
            ],
            const SizedBox(height: Spacing.sm),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Keep looking at it'),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================= already decided

final class _SettledCard extends StatelessWidget {
  const _SettledCard({required this.item});

  final PortalApprovalItem item;

  @override
  Widget build(BuildContext context) {
    final note = item.lastNote?.trim();
    final dh = context.dh;

    return DhCard(
      tone: DhCardTone.inset,
      accent: item.isSentBack ? context.scheme.secondary : dh.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OrderLine(
            code: item.job.displayCode,
            title: item.job.displayTitle,
            trailing: DecisionChip(item, dense: true),
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              StatusChip(label: item.kind.label, tone: ChipTone.neutral, dense: true),
              const SizedBox(width: Spacing.sm),
              StatusChip.code(item.subjectLabel, dense: true),
              if (item.amount != null) ...[
                const SizedBox(width: Spacing.sm),
                Flexible(
                  child: Text(
                    item.amount!.format(),
                    style: AppTheme.mono(
                      size: 12.5,
                      weight: FontWeight.w600,
                      color: context.scheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            PortalNote(
              tone: item.isSentBack ? PortalNoteTone.calm : PortalNoteTone.settled,
              icon: Icons.format_quote_rounded,
              text: note,
            ),
          ],
        ],
      ),
    );
  }
}
