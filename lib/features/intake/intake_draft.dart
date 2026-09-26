/// Everything the intake wizard is holding for one job, and every rule that decides whether a
/// step may be left.
///
/// The gates live here rather than in the eleven screens because the review step has to be able
/// to say *which* earlier step is unfinished, and a rule written twice is a rule that will
/// disagree with itself. Each screen reads [IntakeDraft.blockReasonFor] and hands it straight to
/// `WizardScaffold.ctaBlockedReason`, which disables the button and prints the sentence above it.
///
/// Two of the four D-011 rules are enforced from this file:
///   * rule 4 — media capture, satisfied by a photo **or** a voice note **or** an uploaded file;
///   * the custody block and `stones.origin`, through `Stone.openQuestions`, which is why neither
///     can be skipped by a screen forgetting to ask.
library;

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/spec_repository.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
// `StageRail` is both a data aggregate in `domain/models/job_stage.dart` and a widget in the
// shared set. This file needs the data one, so the widget name is hidden rather than prefixed.
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;
import 'package:freezed_annotation/freezed_annotation.dart';

part 'intake_draft.freezed.dart';

/// Where autosave stands, for the badge in the wizard header.
enum SaveState { idle, saving, saved, failed }

/// The GST the job will be invoiced at, summed across the quote's cost lines.
///
/// D-004: an Indian manufacturer cannot legally ship without a tax invoice, and the split is not
/// one rate — jewellery is 3%, making charges 5%, certification 18%. So this carries the per-rate
/// breakdown as well as the total, because an operator checking a quote checks the bands.
final class GstPreview {
  const GstPreview({
    required this.taxable,
    required this.cgst,
    required this.sgst,
    required this.igst,
    required this.interstate,
    required this.byRate,
  });

  final Money taxable;
  final Money cgst;
  final Money sgst;
  final Money igst;

  /// Interstate supply is IGST; intrastate splits into CGST + SGST. Decided by comparing the
  /// first two digits of the customer's GSTIN with the workshop's.
  final bool interstate;

  /// Rate percentage → tax charged at that rate.
  final Map<double, Money> byRate;

  Money get tax => cgst + sgst + igst;
  Money get total => taxable + tax;

  /// 'IGST 3% + 5%' / 'CGST + SGST' — what will print on the invoice.
  String get headingLabel => interstate ? 'IGST (interstate supply)' : 'CGST + SGST (intrastate)';
}

@freezed
class IntakeDraft with _$IntakeDraft {
  const IntakeDraft._();

  const factory IntakeDraft({
    /// Null until step 1 mints the `DRAFT-<4 char>` row. Everything else is keyed off it.
    Job? job,
    Customer? customer,
    Org? org,
    ProductSpec? productSpec,
    MetalSpec? metalSpec,
    @Default(<Stone>[]) List<Stone> stones,
    @Default(<MeleeParcel>[]) List<MeleeParcel> melee,
    DeliverySchedule? delivery,
    AcceptanceCriteria? acceptance,
    Quote? quote,
    @Default(<ApprovalGate>[]) List<ApprovalGate> gates,
    @Default(<Attachment>[]) List<Attachment> attachments,
    @Default(<JobReference>[]) List<JobReference> references,
    StageRail? rail,

    /// Who holds the CAD stage after commit, resolved for step 11's confirmation line.
    AppUser? cadAssignee,
    @Default(IntakeStep.jobType) IntakeStep step,
    @Default(SaveState.idle) SaveState save,
    DateTime? savedAt,
    String? saveError,
  }) = _IntakeDraft;

  // ---------------------------------------------------------------- identity

  bool get hasJob => job != null;

  /// Steps 2–11 are unreachable before the `DRAFT-` row exists — the wizard stands on step 1
  /// until it does. Asserting that here once is what keeps ten screens free of `job!`.
  Job get requireJob =>
      job ??
      (throw StateError(
        'The intake wizard reached step ${step.number} with no draft row. Step 1 creates it.',
      ));

  /// 'DRAFT-992A' before commit, 'DH-2026-01842' after (D-001).
  String get displayCode => job?.displayCode ?? 'New job';

  bool get isCommitted => job?.isCommitted ?? false;

  /// D-004. Every Money in the wizard is built against this, never against a literal.
  String get currency => job?.currency ?? org?.baseCurrency ?? 'INR';

  Money get zero => Money(0, currency);

  Money money(int minor) => Money(minor, currency);

  JobType? get jobType => job?.jobType;
  ProductCategory? get category => job?.category;
  ProductSubStyle? get subStyle => job?.subStyle;

  // ---------------------------------------------------------------- flow

  /// REQ-GEM-03. An explicit "No stones" skips step 6 outright. Null means unanswered, which
  /// skips nothing — the mockup's CTA read PROCEED TO STONES either way.
  bool get skipsStones => metalSpec?.skipsStoneStep ?? false;

  bool isSkipped(IntakeStep candidate) =>
      candidate == IntakeStep.stones && skipsStones;

  IntakeStep? nextAfter(IntakeStep from) {
    for (var n = from.number + 1; n <= IntakeStep.total; n++) {
      final candidate = IntakeStep.fromNumber(n);
      if (candidate.number != n) return null;
      if (!isSkipped(candidate)) return candidate;
    }
    return null;
  }

  IntakeStep? previousBefore(IntakeStep from) {
    for (var n = from.number - 1; n >= 1; n--) {
      final candidate = IntakeStep.fromNumber(n);
      if (!isSkipped(candidate)) return candidate;
    }
    return null;
  }

  /// "Continue to Metal" — never "Next". The label names the step it opens, so an operator who
  /// skipped stones sees the truth rather than a promise the wizard will not keep.
  String ctaLabelFor(IntakeStep current) {
    if (current == IntakeStep.review) {
      return gates.isEmpty ? 'Send for Approval' : 'Create Job Order';
    }
    final next = nextAfter(current);
    return next == null ? 'Finish' : 'Continue to ${next.shortLabel}';
  }

  // ---------------------------------------------------------------- capture (D-011 rule 4)

  /// The same partition `SpecRepository.captureGate` makes, computed locally so the gate opens
  /// the instant an upload lands instead of after a round trip.
  CaptureGate get capture {
    final photos = <Attachment>[];
    final voice = <Attachment>[];
    final files = <Attachment>[];
    for (final a in attachments) {
      if (!a.satisfiesCaptureGate) continue;
      if (a.isVoiceNote) {
        voice.add(a);
      } else if (a.isImage) {
        photos.add(a);
      } else {
        files.add(a);
      }
    }
    return CaptureGate(
      references: references,
      photos: photos,
      voiceNotes: voice,
      files: files,
    );
  }

  /// The `job_references` row that points at [a], if the capture was filed as a reference.
  JobReference? referenceFor(Attachment a) {
    for (final r in references) {
      if (r.attachmentId == a.id) return r;
    }
    return null;
  }

  // ---------------------------------------------------------------- stones

  /// Mirrors `SpecRepository.stoneGaps`, off the same `Stone.openQuestions` rule — origin and the
  /// whole custody block included.
  List<StoneGap> get stoneGaps => [
        for (final stone in stones)
          if (stone.openQuestions.isNotEmpty)
            StoneGap(
              stoneId: stone.id,
              label: stone.displayTitle,
              missing: List<String>.unmodifiable(stone.openQuestions),
              custodyMissing: List<String>.unmodifiable(stone.missingCustodyFields),
            ),
      ];

  Stone? get centreStone {
    for (final s in stones) {
      if (s.role == StoneRole.center) return s;
    }
    return null;
  }

  /// Any stone the shop is holding for a client. Drives the custody card and the review warning.
  List<Stone> get custodyStones =>
      [for (final s in stones) if (s.isCustomerSupplied) s];

  double get totalCarat {
    var sum = 0.0;
    for (final s in stones) {
      sum += s.carat ?? 0;
    }
    for (final p in melee) {
      sum += p.totalCtw ?? 0;
    }
    return sum;
  }

  // ---------------------------------------------------------------- delivery

  Priority get priority => delivery?.priority ?? job?.priority ?? Priority.standard;

  /// The buffer between "off the bench" and "out of the door". The mockup hardcoded two days
  /// regardless of priority, with its own source carrying the comment "Could adjust buffers here
  /// based on priority" — this is what that comment meant.
  int get dispatchBufferDays =>
      delivery?.dispatchBufferD ??
      switch (priority) {
        Priority.standard => 2,
        Priority.rush || Priority.critical => 1,
      };

  /// Zero when no lab will see the piece — the cross-screen dependency `CertLab.none` declares.
  int get certBufferDays {
    final stored = delivery?.certBufferD;
    if (stored != null) return stored;
    return (acceptance?.skipsCertification ?? false) ? 0 : 3;
  }

  /// Days on the bench before any buffer: CAD, approval, wax, casting, assembly, setting,
  /// polishing and QC. A rush job buys fewer of them, not a faster courier.
  int get benchLeadDays => switch (priority) {
        Priority.standard => 12,
        Priority.rush => 8,
        Priority.critical => 5,
      };

  int get leadDays => benchLeadDays + dispatchBufferDays + certBufferDays;

  static DateTime get today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// The soonest date this job can honestly be promised.
  DateTime get earliestDelivery => today.add(Duration(days: leadDays));

  /// The date the piece has to be finished on the bench to hit the requested delivery.
  DateTime? get benchTarget {
    final requested = delivery?.requestedDate ?? job?.requestedDelivery;
    if (requested == null) return null;
    return requested.subtract(Duration(days: dispatchBufferDays + certBufferDays));
  }

  bool get deliveryIsInPast {
    final requested = delivery?.requestedDate ?? job?.requestedDelivery;
    if (requested == null) return false;
    return DateTime(requested.year, requested.month, requested.day).isBefore(today);
  }

  bool get deliveryBeatsLeadTime {
    final requested = delivery?.requestedDate ?? job?.requestedDelivery;
    if (requested == null) return false;
    return DateTime(requested.year, requested.month, requested.day)
        .isBefore(earliestDelivery);
  }

  // ---------------------------------------------------------------- commercials

  Money get quoteSubtotal => quote?.subtotal ?? zero;
  Money get quoteTax => quote?.taxTotal ?? zero;
  Money get quoteTotal => quote?.grandTotal ?? zero;

  /// The ceiling the total is measured against: the approved maximum if one was set, otherwise
  /// REQ-FIN-04's budget band from the metal step.
  Money? get costCeiling =>
      quote?.maxApproved ?? metalSpec?.targetBudgetMax(currency);

  Money? get costTarget =>
      quote?.targetUnitPrice ?? metalSpec?.targetBudgetMin(currency);

  /// 0.0–1.0+ against the ceiling. Null when nobody has set one, because a bar with no ceiling
  /// is a bar that always reads "fine".
  double? get envelopeUsed {
    final ceiling = costCeiling;
    if (ceiling == null || ceiling.isZero) return null;
    return quoteTotal.minor / ceiling.minor;
  }

  bool get isOverEnvelope {
    final ceiling = costCeiling;
    return ceiling != null && !ceiling.isZero && quoteTotal.minor > ceiling.minor;
  }

  GstPreview? get gst {
    final q = quote;
    if (q == null || q.lines.isEmpty) return null;
    final interstate = customer?.isInterstateFrom(org?.gstin) ?? true;
    var taxable = Money(0, q.currency);
    var cgst = Money(0, q.currency);
    var sgst = Money(0, q.currency);
    var igst = Money(0, q.currency);
    final byRate = <double, Money>{};
    for (final line in q.lines) {
      // A client's own stone is in our care, not on our invoice.
      if (line.isClientOwned) continue;
      final band = line.gst(currency: q.currency, interstate: interstate);
      taxable += band.taxable;
      cgst += band.cgst;
      sgst += band.sgst;
      igst += band.igst;
      byRate.update(
        line.effectiveTaxRatePct,
        (running) => running + band.tax,
        ifAbsent: () => band.tax,
      );
    }
    return GstPreview(
      taxable: taxable,
      cgst: cgst,
      sgst: sgst,
      igst: igst,
      interstate: interstate,
      byRate: byRate,
    );
  }

  Map<CostCategory, Money> get costByCategory =>
      quote?.byCategory ??
      {for (final c in CostCategory.values) c: zero};

  // ---------------------------------------------------------------- approval gates

  ApprovalGate? gateOf(ApprovalGateKind kind) {
    for (final g in gates) {
      if (g.kind == kind) return g;
    }
    return null;
  }

  bool get allGatesApproved =>
      gates.length == ApprovalGateKind.values.length &&
      gates.every((g) => g.isApproved);

  List<ApprovalGate> get pendingGates => [for (final g in gates) if (g.isPending) g];

  List<ApprovalGate> get rejectedGates => [for (final g in gates) if (g.isRejected) g];

  // ---------------------------------------------------------------- gates per step

  /// Message → satisfied, in the order the operator should fix them. Feed straight into
  /// `WizardScaffold.firstUnmet`; map literals keep insertion order, so the cheapest fix is first.
  Map<String, bool> gatesFor(IntakeStep step) => switch (step) {
        IntakeStep.jobType => {
            'Choose the kind of work before continuing.': jobType != null,
          },
        IntakeStep.media => {
            // D-011 rule 4, extended past the mockup's camera-only gate.
            'Capture at least one reference before continuing — a photo, a voice note, '
                'or an uploaded sketch.': capture.isSatisfied,
            'Choose who the piece is for. A job order with no customer cannot be invoiced.':
                job?.customerId != null,
          },
        IntakeStep.category => _categoryGates,
        IntakeStep.design => _designGates,
        IntakeStep.metal => _metalGates,
        IntakeStep.stones => _stoneGates,
        IntakeStep.commercials => _commercialGates,
        IntakeStep.delivery => _deliveryGates,
        IntakeStep.quality => _qualityGates,
        IntakeStep.review => _reviewGates,
        IntakeStep.created => const <String, bool>{},
      };

  Map<String, bool> get _categoryGates {
    final c = category;
    final styles = c == null ? const <ProductSubStyle>[] : ProductSubStyle.forCategory(c);
    return {
      'Choose what kind of piece this is.': c != null,
      if (styles.length > 1)
        'Choose the style. "Engagement Ring" and "Eternity Band" are built differently.':
            subStyle != null,
    };
  }

  Map<String, bool> get _designGates {
    final c = category;
    if (c == null) return {'Choose a product category first.': false};
    final spec = productSpec;
    final missing = spec?.missingFor(c) ?? const <String>['Setting style'];
    return {
      if (missing.isNotEmpty)
        '${missing.first} is still blank. The bench cannot cut metal without it.': false,
    };
  }

  Map<String, bool> get _metalGates {
    final m = metalSpec;
    final metal = m?.baseMetal;
    final purity = m?.purity;
    return {
      'Choose the base metal — REQ-MAT-01.': metal != null,
      'Choose the alloy purity — REQ-PUR-02.': purity != null,
      if (metal != null && purity != null)
        '${purity.label} ${metal.label.toLowerCase()} is not a product. '
            'Pick a purity this metal is actually made in.': m!.purityIsValid,
      'Say whether the piece is set with stones — REQ-GEM-03. '
          'Answering No skips the stone step entirely.': m?.gemstoneInset != null,
    };
  }

  Map<String, bool> get _stoneGates {
    final gaps = stoneGaps;
    return {
      'Add the stones, or go back and answer No to gemstone inset (REQ-GEM-03).':
          stones.isNotEmpty || melee.isNotEmpty,
      if (gaps.isNotEmpty) gaps.first.summary: false,
    };
  }

  Map<String, bool> get _commercialGates {
    final q = quote;
    return {
      'Add at least one cost line so the job has a price.': q != null && q.lines.isNotEmpty,
      if (q != null)
        'Cost Plus needs a margin. Enter the percentage you are adding on top of cost.':
            !q.needsMargin,
    };
  }

  Map<String, bool> get _deliveryGates {
    final requested = delivery?.requestedDate ?? job?.requestedDelivery;
    return {
      'Pick the date the customer needs the piece.': requested != null,
      'That date has already passed. Pick today or later.': !deliveryIsInPast,
      'This job needs $leadDays days end to end. The earliest honest date is '
          '${_dayLabel(earliestDelivery)} — move the date, or raise the priority.':
          !deliveryBeatsLeadTime,
    };
  }

  Map<String, bool> get _qualityGates {
    final a = acceptance;
    return {
      'Name the lab. Choosing "Other" without a name leaves QC nothing to send the piece to.':
          !(a?.certLabNeedsName ?? false),
      'Enter the tolerance in millimetres, or turn strict tolerance back off.':
          !((a?.strictTolerance ?? false) && a?.toleranceMm == null),
    };
  }

  /// The review step's call to action is two-phase, and so is its gate.
  ///
  /// With no gate rows yet the button *is* "Send for Approval" — so the absence of gates cannot
  /// also be what blocks it, or the step is a dead end: a disabled button whose stated fix is the
  /// thing the button does. Once the three rows exist the button becomes "Create Job Order", and
  /// every unresolved gate blocks it. `fn_commit_job` enforces the same rule server-side, which
  /// is what actually stops an unapproved job reaching the shop floor.
  Map<String, bool> get _reviewGates {
    final open = incompleteSteps;
    return {
      if (open.isNotEmpty)
        'Step ${open.first.number} — ${open.first.shortLabel} is not finished. '
            '${blockReasonFor(open.first) ?? ''}'.trim(): false,
      if (gates.isNotEmpty) ...{
        if (rejectedGates.isNotEmpty)
          '${rejectedGates.first.kind.label} was rejected: '
              '${rejectedGates.first.note ?? 'no reason recorded'}.': false,
        if (pendingGates.isNotEmpty)
          '${pendingGates.first.kind.label} is still pending. '
              '${pendingGates.first.decidingRole.label} has to clear it.': false,
        if (!allGatesApproved && rejectedGates.isEmpty && pendingGates.isEmpty)
          'All three approval gates have to be on the record before a job number is minted.':
              false,
      },
    };
  }

  /// The first thing stopping [step], or null when it is finished.
  String? blockReasonFor(IntakeStep step) =>
      WizardScaffold.firstUnmet(gatesFor(step));

  bool isSatisfied(IntakeStep step) => blockReasonFor(step) == null;

  /// Every form step still unfinished, in order. The review screen lists these with a jump link
  /// each, so an operator never has to hunt for what is missing.
  List<IntakeStep> get incompleteSteps => [
        for (final candidate in IntakeStep.form)
          if (candidate != IntakeStep.review &&
              !isSkipped(candidate) &&
              !isSatisfied(candidate))
            candidate,
      ];

  /// How much of the form is done, for the review screen's completeness meter.
  double get completeness {
    final counted = [
      for (final candidate in IntakeStep.form)
        if (candidate != IntakeStep.review && !isSkipped(candidate)) candidate,
    ];
    if (counted.isEmpty) return 1;
    final done = counted.where(isSatisfied).length;
    return done / counted.length;
  }

  static String _dayLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}
