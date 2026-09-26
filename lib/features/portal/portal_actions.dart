/// Every write the retailer's portal makes, in one place, with one busy flag.
///
/// Three decisions, and each carries the same asymmetry D-011 rule 2 established: **agreement owes
/// nobody an explanation, refusal does.** Approving a design, a wax or a price takes one tap;
/// sending any of them back requires a sentence, because the workshop cannot act on "no".
///
/// `pricing_approval` is the screen this file answers. Its only exit was "Approve" — no rejection,
/// no counter-offer, nowhere to put a number. D-006 restores all three ([PriceVerdict]).
///
/// **How a customer decision is recorded, and why it is not just a status column.**
///
///  * The decision of record is an `activity_events` row, written by
///    [PortalGateway.recordDecision]. Postgres has UPDATE and DELETE revoked on that table, so a
///    client's sign-off cannot later be edited into something else — which is what D-005 means by
///    "who approved what, when must be reconstructible", and what `certification` called an
///    Immutable Audit Trail while hardcoding its contents.
///  * A thread post carries the reasoning, customer-visible, so the workshop reads it where they
///    read everything else about the job.
///  * The domain row — `cad_reviews`, or `quotes.status` — is then updated where the schema lets
///    a customer do it.
///
/// That last step is where the schema is currently short, and this file is honest about it rather
/// than pretending. `0009_rls.sql` generates one write policy per job-scoped table:
/// `using (auth_principal() = 'internal' …) with check (auth_can_see_job(job_id))`. An INSERT
/// evaluates only the check, so a customer *can* insert a `cad_reviews` row — the design decision
/// lands properly. An UPDATE also evaluates `using`, which a customer fails, so
/// `QuoteRepository.approveQuote` updates **zero rows and raises nothing**: PostgREST reports a
/// no-op update as success. [PortalActions.decidePrice] therefore re-reads the quote and reports
/// [PortalDecisionOutcome.needsCountersign] when the status did not move, so the client is told
/// the truth — their decision is on the record and the workshop has to countersign it — instead of
/// watching a button do nothing. The fix belongs in a migration: a customer UPDATE policy limited
/// to the decision columns, or an `fn_decide_quote` with `security definer`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/repositories/quote_repository.dart';
import 'package:dhanaos/data/repositories/thread_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/portal/portal_gateway.dart';

part 'portal_actions.g.dart';

/// What the customer can say about a price. D-006: `pricing_approval` offered only the first.
enum PriceVerdict {
  approve('Approve the price', 'We are happy with this. Go ahead.'),
  counter('Make a counter-offer', 'Propose a figure and say what it is based on.'),
  refuse('Refuse the price', 'Say why, so the workshop can re-quote.');

  const PriceVerdict(this.label, this.blurb);

  final String label;
  final String blurb;

  bool get isApproval => this == approve;

  /// Refusal and a counter both owe the workshop a reason; agreement does not.
  bool get needsReason => this != approve;

  bool get needsAmount => this == counter;
}

/// Which portal write is in flight, so the screen spins the control that was pressed rather than
/// greying out every decision on the page.
enum PortalTask { design, wax, price }

/// What actually happened, so the screen can say something true.
///
/// [needsCountersign] is not a failure: the decision is recorded and immutable either way. It
/// means the workshop's own copy of the document has not moved yet, and the client should be told
/// that rather than left to wonder why the status chip did not change.
final class PortalDecisionOutcome {
  const PortalDecisionOutcome({
    required this.approved,
    required this.needsCountersign,
    this.note,
  });

  final bool approved;
  final bool needsCountersign;

  /// The reason the customer gave, trimmed. Kept so the screen can echo it back.
  final String? note;

  /// The sentence to show. Written from the client's side of the screen.
  String message(String subject) {
    if (needsCountersign) {
      return approved
          ? 'Your approval of $subject is recorded. The workshop countersigns it their end and '
              'will confirm.'
          : 'Your decision on $subject is recorded and the workshop has it. They will come back '
              'to you.';
    }
    return approved
        ? '$subject approved. The workshop can carry on.'
        : 'Sent back to the workshop with your note.';
  }
}

/// Kept alive for the same reason the other action notifiers are: an approval must survive the
/// client flicking to another screen while the round trip is open. An auto-disposed notifier would
/// be torn down under its own `finally`.
@Riverpod(keepAlive: true)
class PortalActions extends _$PortalActions {
  /// Null when nothing is in flight.
  @override
  PortalTask? build() => null;

  bool get isBusy => state != null;

  bool isRunning(PortalTask task) => state == task;

  PortalGateway get _gateway => ref.read(portalGatewayProvider);

  // -------------------------------------------------------------- design

  /// D-011 rule 2, from the customer's side.
  ///
  /// `cad_reviews` carries the `cad_reject_needs_comment` CHECK, so an empty comment on a
  /// rejection is refused by Postgres in its own words and this method does not pre-empt it —
  /// the rule cannot be weakened by a client rewrite. [CadReview.canSubmit] is what holds the
  /// button shut so the client normally never meets the refusal.
  ///
  /// One thing does not land for a customer and is not pretended otherwise:
  /// `ProductionRepository.submitCadReview` also sets `cad_revisions.is_locked` on approval, and
  /// `cad_revisions_write` is internal-only for UPDATE. The review row is the decision of record;
  /// the lock is the workshop's bookkeeping and follows when they see it.
  Future<PortalDecisionOutcome> decideDesign({
    required PortalApprovalItem item,
    required bool approved,
    String? comment,
  }) async {
    final revision = item.revision;
    if (revision == null) {
      throw const RuleViolation(
        message: 'There is no drawing to decide on yet. The workshop will send one through.',
        code: 'portal_no_revision',
      );
    }
    final note = comment?.trim();
    if (!CadReview.canSubmit(approved: approved, comment: note)) {
      throw const RuleViolation(
        message: CadReview.rejectionNeedsComment,
        code: 'cad_reject_needs_comment',
      );
    }

    state = PortalTask.design;
    try {
      await ref.read(productionRepositoryProvider).submitCadReview(
            revisionId: revision.id,
            approved: approved,
            comment: note,
          );

      await _gateway.recordDecision(
        jobId: item.jobId,
        // The design decision closes — or sends back — the CAD stage, so it is stamped there.
        stage: LifecycleStage.cad,
        approved: approved,
        summary: approved
            ? 'Client approved CAD ${revision.version}'
            : 'Client requested changes to CAD ${revision.version}',
        detail: note,
        payload: <String, dynamic>{'revision_id': revision.id, 'version': revision.version},
      );
      await _post(item.jobId, LifecycleStage.cad, _designNote(revision, approved, note));

      return PortalDecisionOutcome(approved: approved, needsCountersign: false, note: note);
    } finally {
      state = null;
      _refresh(item.jobId);
    }
  }

  static String _designNote(CadRevision revision, bool approved, String? note) => approved
      ? 'Approved CAD ${revision.version}.'
      : 'Requested changes to CAD ${revision.version}.\n\n${note ?? ''}'.trim();

  // -------------------------------------------------------------- wax

  /// The wax sign-off.
  ///
  /// There is no `wax_reviews` table and there should not be one: this is a client saying yes or
  /// no to a physical object, and the record that matters is the audit entry. `quality_acceptance`
  /// offered "Customer" as a sign-off authority and built no transition and no screen behind it —
  /// [AcceptanceCriteria.needsCustomerGate] is what decides whether this gate applies at all, so a
  /// shop that signs its own waxes never sees it.
  ///
  /// The stage is not advanced from here. A client approving a wax does not close the stage; the
  /// bench does, once the wax is actually cast. What this write does is unblock them.
  Future<PortalDecisionOutcome> decideWax({
    required PortalApprovalItem item,
    required bool approved,
    String? comment,
  }) async {
    final note = comment?.trim();
    if (!approved && (note == null || note.isEmpty)) {
      throw const RuleViolation(
        message: 'Tell the workshop what to change about the wax. They cannot rework a shape '
            'nobody described.',
        code: 'portal_wax_needs_reason',
      );
    }

    state = PortalTask.wax;
    try {
      await _gateway.recordDecision(
        jobId: item.jobId,
        stage: LifecycleStage.wax,
        approved: approved,
        summary: approved ? 'Client approved the wax model' : 'Client rejected the wax model',
        detail: note,
      );
      await _post(
        item.jobId,
        LifecycleStage.wax,
        approved
            ? 'Approved the wax model.${note == null || note.isEmpty ? '' : '\n\n$note'}'
            : 'Asked for changes to the wax model.\n\n$note',
      );
      return PortalDecisionOutcome(approved: approved, needsCountersign: false, note: note);
    } finally {
      state = null;
      _refresh(item.jobId);
    }
  }

  // -------------------------------------------------------------- price

  /// D-006 — the three exits `pricing_approval` reduced to one.
  ///
  /// The order of writes is deliberate. The audit entry goes first because it is the client's
  /// decision of record and it always lands; the thread post carries the reasoning; the quote
  /// transition is attempted last and verified, because a customer's UPDATE on `quotes` is refused
  /// by RLS as a silent no-op rather than an error (see the library comment). Whichever way that
  /// goes, the decision is never lost and the client is never told it worked when it did not.
  Future<PortalDecisionOutcome> decidePrice({
    required PortalApprovalItem item,
    required PriceVerdict verdict,
    Money? counterAmount,
    String? reason,
  }) async {
    final quote = item.quote;
    if (quote == null) {
      throw const RuleViolation(
        message: 'There is no quote to decide on yet.',
        code: 'portal_no_quote',
      );
    }

    final note = reason?.trim();
    if (verdict.needsReason && (note == null || note.isEmpty)) {
      throw RuleViolation(
        message: verdict == PriceVerdict.counter
            ? 'Say what the counter-offer is based on. A number with no reasoning cannot be '
                'negotiated against.'
            : 'Say why the price was refused. Without a reason nobody can re-quote it.',
        code: 'decision_note_required',
      );
    }
    if (verdict.needsAmount && counterAmount == null) {
      throw const RuleViolation(
        message: 'Enter the figure you are offering.',
        code: 'portal_counter_needs_amount',
      );
    }
    // A quote in two currencies is not a quote — `QuoteRepository.counterOffer` refuses it too,
    // but refusing here means the client is told before the round trip rather than after.
    if (counterAmount != null && counterAmount.currency != quote.currency) {
      throw RuleViolation(
        message: 'The quote is in ${quote.currency}. Enter your offer in ${quote.currency} too.',
        detail: 'counter=${counterAmount.currency} quote=${quote.currency}',
        code: 'portal_currency_mismatch',
      );
    }

    final approved = verdict.isApproval;
    state = PortalTask.price;
    try {
      await _gateway.recordDecision(
        jobId: item.jobId,
        stage: LifecycleStage.pricing,
        approved: approved,
        summary: switch (verdict) {
          PriceVerdict.approve => 'Client approved quote v${quote.version} '
              '(${quote.grandTotal.format()})',
          PriceVerdict.counter => 'Client counter-offered on quote v${quote.version}: '
              '${counterAmount!.format()}',
          PriceVerdict.refuse => 'Client refused quote v${quote.version}',
        },
        detail: note,
        payload: <String, dynamic>{
          'quote_id': quote.id,
          'version': quote.version,
          'grand_total_minor': quote.grandTotalMinor,
          'currency': quote.currency,
          if (counterAmount != null) 'counter_minor': counterAmount.minor,
        },
      );

      await _post(item.jobId, LifecycleStage.pricing, _priceNote(quote, verdict, counterAmount, note));

      final settled = await _applyToQuote(
        quoteId: quote.id,
        verdict: verdict,
        counterAmount: counterAmount,
        note: note,
      );
      return PortalDecisionOutcome(
        approved: approved,
        needsCountersign: !settled,
        note: note,
      );
    } finally {
      state = null;
      _refresh(item.jobId);
    }
  }

  /// Move `quotes.status`, and say whether it actually moved.
  ///
  /// Returns false when the row came back unchanged — the RLS no-op described in the library
  /// comment. It deliberately does not throw: the customer's decision is already immutable on the
  /// audit trail, and turning a recorded decision into a red error would send them round again.
  Future<bool> _applyToQuote({
    required String quoteId,
    required PriceVerdict verdict,
    Money? counterAmount,
    String? note,
  }) async {
    final quotes = ref.read(quoteRepositoryProvider);
    final expected = switch (verdict) {
      PriceVerdict.approve => QuoteStatus.approved,
      PriceVerdict.counter => QuoteStatus.counterOffered,
      PriceVerdict.refuse => QuoteStatus.rejected,
    };

    try {
      final updated = switch (verdict) {
        PriceVerdict.approve => await quotes.approveQuote(quoteId: quoteId, note: note),
        PriceVerdict.refuse => await quotes.rejectQuote(quoteId: quoteId, note: note!),
        PriceVerdict.counter => await quotes.counterOffer(
            quoteId: quoteId,
            amount: counterAmount!,
            note: note!,
          ),
      };
      return updated.status == expected;
    } on DhFailure catch (_) {
      // Swallowed deliberately, and only here. The client's decision is already immutable in
      // `activity_events` and their reasoning is already on the thread, so every failure of this
      // last step has the same true answer: recorded, awaiting the workshop's countersignature.
      // Re-throwing would show a red error over a decision that did land, and the client would
      // press it again.
      return false;
    }
  }

  static String _priceNote(
    Quote quote,
    PriceVerdict verdict,
    Money? counterAmount,
    String? note,
  ) {
    final head = switch (verdict) {
      PriceVerdict.approve =>
        'Approved quote v${quote.version} at ${quote.grandTotal.format()}.',
      PriceVerdict.counter => 'Counter-offer on quote v${quote.version}: '
          '${counterAmount!.format()} against ${quote.grandTotal.format()}.',
      PriceVerdict.refuse => 'Refused quote v${quote.version} at ${quote.grandTotal.format()}.',
    };
    return note == null || note.isEmpty ? head : '$head\n\n$note';
  }

  // -------------------------------------------------------------- plumbing

  /// A post on the job's thread, carrying the client's reasoning.
  ///
  /// Never internal. This is the client speaking, and `thread_select` hides internal posts from a
  /// customer principal — an internal post written by a customer would be invisible to its own
  /// author, which is the worst possible default. The mockups ran one feed for everybody and had
  /// no flag at all, which is the opposite mistake.
  ///
  /// Best effort. The decision is already immutable in `activity_events`; a post that did not land
  /// must not turn a recorded approval into a reported failure.
  Future<void> _post(String jobId, LifecycleStage stage, String body) async {
    try {
      await ref.read(threadRepositoryProvider).postMessage(
            jobId: jobId,
            body: body,
            stage: stage,
            isInternal: false,
          );
    } on DhFailure catch (_) {
      // Intentionally ignored — see the doc comment.
    }
  }

  /// Invalidated even on failure: every decision writes the audit row before anything else can go
  /// wrong, so the screen must re-read rather than keep showing an open decision.
  void _refresh(String jobId) {
    ref
      ..invalidate(portalApprovalsProvider)
      ..invalidate(portalJobViewProvider(jobId));
  }
}

/// The customer's own message on their order.
///
/// Separate from [PortalActions] because it is not a decision and should not share a busy flag
/// with one: a client typing a question while an approval is in flight must not find the send
/// button dead.
@riverpod
class PortalComposer extends _$PortalComposer {
  @override
  FutureOr<void> build(String jobId) {}

  /// Returns the failure to show, or null when the message landed.
  ///
  /// Always `isInternal: false`. A customer's own post marked internal would be filtered straight
  /// back out by `thread_select` and vanish in front of them.
  Future<DhFailure?> post(String body) async {
    state = const AsyncLoading<void>().copyWithPrevious(state);
    try {
      await ref.read(threadRepositoryProvider).postMessage(
            jobId: jobId,
            body: body,
            isInternal: false,
          );
      state = const AsyncData<void>(null);
      return null;
    } on Object catch (error, stack) {
      final failure = toDhFailure(error, stack);
      state = AsyncError<void>(failure, stack);
      return failure;
    }
  }
}
