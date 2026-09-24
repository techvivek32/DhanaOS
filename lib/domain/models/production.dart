/// CAD, casting, bench measurement, QC, certification and shipping.
///
/// Three of the four business rules ported verbatim from the mockups live here (D-011):
///   rule 1 — casting cannot complete without a photo        ([CastingParams.canComplete])
///   rule 2 — "Request Revisions" needs a comment, "Approve" does not ([CadReview.canSubmit])
///   rule 3 — QC authorisation enables only at a full checklist  ([QcInspection.canAuthorize])
/// Each is also enforced in Postgres, so a client rewrite cannot weaken one.
library;

import 'package:collection/collection.dart';
import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:dhanaos/domain/models/units.dart';
import 'package:dhanaos/domain/models/wire_enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'production.freezed.dart';
part 'production.g.dart';

// ---------------------------------------------------------------- CAD

/// `cad_revisions` — one row per version offered to the customer. Approval locks the row, so a
/// customer who approved v2.0 cannot later be shown a changed v2.0.
@freezed
class CadRevision with _$CadRevision {
  const CadRevision._();

  const factory CadRevision({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,

    /// 'v1.2', 'v2.0' — the label the customer sees, kept as text because the shop's own
    /// numbering is not ours to normalise.
    required String version,
    required int seq,
    @JsonKey(name: 'designer_id') String? designerId,

    /// 'Increased the halo melee stones from 1.2mm to 1.5mm for better presence.'
    @JsonKey(name: 'designer_note') String? designerNote,

    /// Attachment ids of the `cad_render` images, in presentation order.
    @JsonKey(name: 'render_ids') @Default(<String>[]) List<String> renderIds,

    /// The STL / STEP the caster downloads.
    @JsonKey(name: 'model_id') String? modelId,
    @JsonKey(name: 'is_current') @Default(true) bool isCurrent,

    /// Set on approval: "Version 2.0 has been locked".
    @JsonKey(name: 'is_locked') @Default(false) bool isLocked,

    /// Structured diff against the previous revision, e.g. {"halo": "0.45ct tw (from 0.3ct)"}.
    /// The mockup wrote that sentence into prose, where nothing could act on it.
    @JsonKey(name: 'spec_diff') @Default(<String, dynamic>{}) Map<String, dynamic> specDiff,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _CadRevision;

  factory CadRevision.fromJson(Map<String, dynamic> json) => _$CadRevisionFromJson(json);

  bool get hasRenders => renderIds.isNotEmpty;

  /// A caster cannot start from a render. No mesh means the revision is not manufacturable yet.
  bool get hasModel => modelId != null;

  /// A locked revision is the record of what was agreed — reviewing it again would rewrite
  /// history rather than move the job forward.
  bool get isReviewable => !isLocked;

  String? get primaryRenderId => renderIds.firstOrNull;

  /// The diff as operator-readable lines: 'halo: 0.45ct tw (from 0.3ct)'.
  List<String> get changeLines =>
      specDiff.entries.map((e) => '${e.key}: ${e.value}').toList();
}

/// `cad_annotations` — a positioned pin on a render. 'Halo stones were too small...'
@freezed
class CadAnnotation with _$CadAnnotation {
  const CadAnnotation._();

  const factory CadAnnotation({
    required String id,
    @JsonKey(name: 'revision_id') required String revisionId,

    /// Percentages, not pixels: the same pin has to land correctly on a phone and a workstation.
    @JsonKey(name: 'x_pct') required double xPct,
    @JsonKey(name: 'y_pct') required double yPct,
    required String body,
    @JsonKey(name: 'author_id') String? authorId,
    @JsonKey(name: 'resolved_at') DateTime? resolvedAt,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _CadAnnotation;

  factory CadAnnotation.fromJson(Map<String, dynamic> json) => _$CadAnnotationFromJson(json);

  bool get isResolved => resolvedAt != null;
  bool get isOpen => resolvedAt == null;
}

/// `cad_reviews` — one decision on one revision.
@freezed
class CadReview with _$CadReview {
  const CadReview._();

  const factory CadReview({
    required String id,
    @JsonKey(name: 'revision_id') required String revisionId,
    @JsonKey(name: 'reviewer_id') String? reviewerId,
    required bool approved,
    String? comment,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _CadReview;

  factory CadReview.fromJson(Map<String, dynamic> json) => _$CadReviewFromJson(json);

  /// D-011 rule 2, ported verbatim from `cad_review_dh_1048`: "Request Revisions" is blocked on
  /// an empty comment; "Approve" is not. Rejection owes the designer a reason. Deliberately
  /// asymmetric — the mockup flashed an error ring and rewrote the placeholder for 2 seconds,
  /// and Postgres carries the same rule as a CHECK constraint.
  static bool canSubmit({required bool approved, required String? comment}) =>
      approved || (comment != null && comment.trim().isNotEmpty);

  /// The error the reject button explains when it is held shut.
  static const rejectionNeedsComment =
      'Add a note explaining what to change. A revision request without a reason gives the '
      'designer nothing to act on.';

  bool get isRejection => !approved;

  bool get isValid => canSubmit(approved: approved, comment: comment);
}

// ---------------------------------------------------------------- casting

/// `casting_params` — the vendor's stage. One row per job.
@freezed
class CastingParams with _$CastingParams {
  const CastingParams._();

  const factory CastingParams({
    @JsonKey(name: 'job_id') required String jobId,
    @JsonKey(name: 'partner_id') String? partnerId,

    /// '18K Yellow Gold'.
    String? alloy,
    @JsonKey(name: 'flask_temp_c') int? flaskTempC,
    @JsonKey(name: 'metal_temp_c') int? metalTempC,
    @JsonKey(name: 'tree_weight_g') double? treeWeightG,

    /// 'Received Aug 11 09:30 AM'.
    @JsonKey(name: 'received_at') DateTime? receivedAt,

    /// 'Expected Aug 12 05:00 PM'.
    @JsonKey(name: 'expected_at') DateTime? expectedAt,
    @JsonKey(name: 'completed_at') DateTime? completedAt,

    /// D-011 rule 1, the single best idea in the corpus: `caster_dashboard` shipped "Mark
    /// Complete" DISABLED behind a mandatory `accept="image/*"` upload, helper "Required before
    /// marking complete". Also enforced in `fn_complete_stage`, so the rule holds even if this
    /// screen is rewritten.
    @JsonKey(name: 'photo_id') String? photoId,
    String? notes,
  }) = _CastingParams;

  factory CastingParams.fromJson(Map<String, dynamic> json) => _$CastingParamsFromJson(json);

  /// D-011 rule 1. Bind the completion button's `onPressed` to this, not to opacity.
  bool get canComplete => photoId != null && !isComplete;

  /// Why the button is shut, phrased for the caster who is looking at it.
  String? get blockedReason {
    if (isComplete) return null;
    if (photoId == null) {
      return 'Upload a photo of the cast tree. It is required before marking this complete.';
    }
    return null;
  }

  bool get hasEvidence => photoId != null;

  bool get isComplete => completedAt != null;

  bool get isLate {
    final due = expectedAt;
    if (due == null || isComplete) return false;
    return due.toUtc().isBefore(DateTime.now().toUtc());
  }

  /// How long the tree has been with the vendor.
  Duration? get timeAtVendor {
    final from = receivedAt;
    if (from == null) return null;
    return (completedAt ?? DateTime.now()).toUtc().difference(from.toUtc());
  }

  /// '650 °C flask · 1020 °C metal' — the two numbers the caster actually sets.
  String get tempLabel {
    final parts = <String>[
      if (flaskTempC != null) '$flaskTempC °C flask',
      if (metalTempC != null) '$metalTempC °C metal',
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  String get treeWeightLabel => gramLabel(treeWeightG);
}

/// `job_exceptions` — `caster_dashboard`'s "Report Issue" was a 50/50 peer of the happy path
/// with no screen behind it. 'Caster delayed'.
@freezed
class JobException with _$JobException {
  const JobException._();

  const factory JobException({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @LifecycleStageConverter() required LifecycleStage stage,
    @JsonKey(name: 'raised_by') String? raisedBy,
    @JsonKey(name: 'partner_id') String? partnerId,
    required String title,
    String? detail,
    @ActionSeverityConverter() @Default(ActionSeverity.warning) ActionSeverity severity,
    @JsonKey(name: 'resolved_at') DateTime? resolvedAt,
    String? resolution,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _JobException;

  factory JobException.fromJson(Map<String, dynamic> json) => _$JobExceptionFromJson(json);

  bool get isOpen => resolvedAt == null;

  /// Raised by a vendor, so resolving it needs a phone call rather than a shop-floor fix.
  bool get isExternal => partnerId != null;

  /// Closing an exception without saying what was done leaves the audit trail useless.
  bool get needsResolution => !isOpen && (resolution?.trim().isEmpty ?? true);

  Duration get age =>
      (resolvedAt ?? DateTime.now()).toUtc().difference(createdAt.toUtc());
}

// ---------------------------------------------------------------- bench

/// `stage_measurements` — what the bench actually weighed.
///
/// NO screen in the mockups captured a production measurement. `order_details` showed the
/// binding spec ("Target Weight 4.2g ±0.1g", the only spec rendered in gold) as read-only while
/// a note in the same thread said "Update spec sheet". This table is that missing surface.
@freezed
class StageMeasurement with _$StageMeasurement {
  const StageMeasurement._();

  const factory StageMeasurement({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @LifecycleStageConverter() required LifecycleStage stage,
    @JsonKey(name: 'measured_by') String? measuredBy,
    @JsonKey(name: 'weight_g') double? weightG,

    /// Copied from the spec at measurement time, so a later spec change cannot retroactively
    /// make a passed measurement fail.
    @JsonKey(name: 'target_g') double? targetG,
    @JsonKey(name: 'tolerance_g') double? toleranceG,

    /// A generated column — Postgres computes it, so it is read-only here.
    @JsonKey(name: 'within_tol', includeToJson: false) bool? withinTol,

    /// Filings, polishing loss and casting sprues. Real, measurable, and never modelled by the
    /// mockups even though their own dashboard raised stock mismatch alerts.
    @JsonKey(name: 'scrap_g') double? scrapG,
    String? notes,
    @JsonKey(name: 'photo_id') String? photoId,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _StageMeasurement;

  factory StageMeasurement.fromJson(Map<String, dynamic> json) =>
      _$StageMeasurementFromJson(json);

  /// Signed: positive is heavy, negative is light. The sign matters — heavy can be filed down,
  /// light cannot be fixed at all.
  double? get varianceG {
    final w = weightG;
    final t = targetG;
    return w == null || t == null ? null : w - t;
  }

  /// Falls back to the local calculation when the generated column has not come back yet (an
  /// insert that did not `select` the row).
  bool get isWithinTolerance {
    final stored = withinTol;
    if (stored != null) return stored;
    final v = varianceG;
    final tol = toleranceG;
    if (v == null || tol == null) return true;
    return v.abs() <= tol;
  }

  /// '+0.12 g' / '-0.04 g'.
  String get varianceLabel {
    final v = varianceG;
    if (v == null) return '—';
    final sign = v > 0 ? '+' : '';
    return '$sign${trimDecimal(v)} g';
  }

  /// '4.32 g vs 4.20 g ± 0.10 g'.
  String get measurementLabel {
    final w = gramLabel(weightG);
    if (targetG == null) return w;
    return '$w vs ${gramLabel(targetG)} ${toleranceLabel(toleranceG)}'.trim();
  }
}

// ---------------------------------------------------------------- QC

/// `qc_inspections` — one attempt. D-006: reinspection after rework gets its own attempt rather
/// than overwriting the failed one.
@freezed
class QcInspection with _$QcInspection {
  const QcInspection._();

  const factory QcInspection({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @Default(1) int attempt,
    @QcStatusConverter() @Default(QcStatus.pending) QcStatus status,
    @JsonKey(name: 'inspector_id') String? inspectorId,
    @QualityAuthorityConverter() @Default(QualityAuthority.internalQc)
    QualityAuthority authority,

    /// The revision the piece is measured against — "Matches approved CAD" is meaningless
    /// without naming which CAD.
    @JsonKey(name: 'cad_revision_id') String? cadRevisionId,

    /// D-006: the mockup had no fail path at all, yet its own JavaScript removed a `bg-error`
    /// class in the else branch — proving a FAILED state was designed and made unreachable.
    /// Postgres requires this text whenever status is `failed`.
    @JsonKey(name: 'defect_reason') String? defectReason,
    String? notes,
    @JsonKey(name: 'authorized_at') DateTime? authorizedAt,
    @JsonKey(name: 'created_at') required DateTime createdAt,

    /// Hydrated by a nested select. Not written back — items are their own rows.
    @JsonKey(name: 'qc_checklist_items', includeToJson: false)
    @Default(<QcChecklistItem>[])
    List<QcChecklistItem> items,
  }) = _QcInspection;

  factory QcInspection.fromJson(Map<String, dynamic> json) => _$QcInspectionFromJson(json);

  /// Items in the order the inspector works them.
  List<QcChecklistItem> get orderedItems =>
      items.sorted((a, b) => a.position.compareTo(b.position));

  int get passedCount => items.where((i) => i.passed == true).length;

  int get failedCount => items.where((i) => i.passed == false).length;

  int get unansweredCount => items.where((i) => i.passed == null).length;

  /// '5/5' — the counter the authorisation button watches.
  String get progressLabel => '$passedCount/${items.length}';

  /// D-011 rule 3: a full checklist. Every item answered, every answer a pass.
  bool get isChecklistComplete =>
      items.isNotEmpty && items.every((i) => i.passed == true);

  /// D-011 rule 3. Bind the authorisation button's `onPressed` to this. `fn_complete_stage`
  /// re-checks it, so a client bypass gains nothing.
  bool get canAuthorize => isChecklistComplete && authorizedAt == null;

  /// Why authorisation is held shut, phrased for the inspector.
  String? get authorizationBlockedReason {
    if (authorizedAt != null) return null;
    if (items.isEmpty) return 'No checklist has been generated for this job yet.';
    if (failedCount > 0) {
      return '$failedCount check${failedCount == 1 ? '' : 's'} failed. Record the defect and '
          'send the piece back for rework.';
    }
    if (unansweredCount > 0) {
      return '$unansweredCount check${unansweredCount == 1 ? '' : 's'} still to confirm.';
    }
    return null;
  }

  /// D-006: the fail path the mockup designed and then made unreachable. Failing owes the bench
  /// a defect reason, the same asymmetry as a CAD rejection.
  bool canFail({required String? reason}) => reason != null && reason.trim().isNotEmpty;

  bool get isAuthorized => authorizedAt != null;

  bool get isFailed => status == QcStatus.failed;

  /// Selecting `customer` as the authority inserts a portal approval gate before sign-off. The
  /// mockups offered the option and had no such transition or screen.
  bool get needsCustomerGate => authority.needsCustomerGate;

  /// A reinspection, so the header can say "Attempt 2" rather than implying a fresh piece.
  bool get isReinspection => attempt > 1;
}

/// `qc_checklist_items` — one line of the inspection, optionally citing a requirement (D-009).
@freezed
class QcChecklistItem with _$QcChecklistItem {
  const QcChecklistItem._();

  const factory QcChecklistItem({
    required String id,
    @JsonKey(name: 'inspection_id') required String inspectionId,
    required int position,

    /// 'Metal weight verified'.
    required String label,

    /// 'Target: 4.8g Pt950. Allowable variance: ±0.2g.' — already reads like a requirement
    /// citation, which is what D-009 formalises.
    String? helper,
    @JsonKey(name: 'requirement_id') String? requirementId,

    /// Three states, not two: null is "not yet checked", false is "checked and failed".
    bool? passed,

    /// The mockup had no file input at all behind its "inspection evidence" dropzone.
    @JsonKey(name: 'evidence_id') String? evidenceId,
    @JsonKey(name: 'checked_by') String? checkedBy,
    @JsonKey(name: 'checked_at') DateTime? checkedAt,
  }) = _QcChecklistItem;

  factory QcChecklistItem.fromJson(Map<String, dynamic> json) =>
      _$QcChecklistItemFromJson(json);

  bool get isAnswered => passed != null;
  bool get isPassed => passed == true;
  bool get isFailed => passed == false;
  bool get hasEvidence => evidenceId != null;

  /// A failed item without a photo is an assertion; with one it is a record.
  bool get needsEvidence => isFailed && evidenceId == null;
}

// ---------------------------------------------------------------- certification

/// `certificates` — the lab leg.
@freezed
class Certificate with _$Certificate {
  const Certificate._();

  const factory Certificate({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,

    /// False must SKIP the certification stage and zero `delivery_schedules.cert_buffer_d`.
    /// Named `isRequired` because `required` is a Dart modifier.
    @JsonKey(name: 'required') @Default(true) bool isRequired,
    @CertLabConverter() @Default(CertLab.igi) CertLab lab,
    @JsonKey(name: 'lab_partner_id') String? labPartnerId,
    @CertStatusConverter() @Default(CertStatus.waiting) CertStatus status,
    @JsonKey(name: 'sent_at') DateTime? sentAt,

    /// No SLA field existed in the mockup, so nothing could ever be chased.
    @JsonKey(name: 'expected_back') DateTime? expectedBack,

    /// 10 digits, hint 'e.g. 1234567890'.
    @JsonKey(name: 'cert_number') String? certNumber,
    @JsonKey(name: 'pdf_id') String? pdfId,

    /// D-006: no lab-rejection path existed in the mockups.
    @JsonKey(name: 'rejection_note') String? rejectionNote,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _Certificate;

  factory Certificate.fromJson(Map<String, dynamic> json) => _$CertificateFromJson(json);

  /// The cross-screen dependency the mockups declared and never wired: no certificate means no
  /// certification stage and no certification buffer.
  bool get skipsStage => !isRequired || lab.skipsStage;

  bool get isBack => status == CertStatus.certified || status == CertStatus.returned;

  bool get isRejected => status == CertStatus.rejected;

  bool get isAtLab => status == CertStatus.sent ||
      status == CertStatus.atLab ||
      status == CertStatus.inProgress;

  /// Past the promised return date and still out.
  bool get isOverdue {
    final due = expectedBack;
    if (due == null || isBack) return false;
    final today = DateTime.now();
    return DateTime(due.year, due.month, due.day)
        .isBefore(DateTime(today.year, today.month, today.day));
  }

  /// A certificate is only in hand when both the number and the PDF are.
  bool get isComplete =>
      (certNumber?.trim().isNotEmpty ?? false) && pdfId != null;

  /// What still has to arrive before the stage can close.
  List<String> get outstanding {
    if (!isRequired) return const [];
    return [
      if (certNumber?.trim().isNotEmpty != true) 'Certificate number',
      if (pdfId == null) 'Certificate PDF',
    ];
  }

  /// 'IGI · 1234567890' / 'IGI · At Lab'.
  String get displayLabel {
    final n = certNumber?.trim();
    return n == null || n.isEmpty ? '${lab.label} · ${status.label}' : '${lab.label} · $n';
  }
}

// ---------------------------------------------------------------- shipping

/// `shipments` — one leg, not one shipment per job. The mockups proved a job needs several:
/// inbound wax from "Central Hub", to-lab ("FEDEX: 9876543210"), from-lab, then final dispatch.
@freezed
class Shipment with _$Shipment {
  const Shipment._();

  const factory Shipment({
    required String id,
    @JsonKey(name: 'job_id') required String jobId,
    @ShipmentLegConverter() required ShipmentLeg leg,
    @ShipmentStatusConverter() @Default(ShipmentStatus.draft) ShipmentStatus status,

    /// `finalDispatch` only: back to the jeweller, or straight to the customer.
    @DispatchRoutingOrNull() DispatchRouting? routing,
    @CourierOrNull() Courier? courier,
    @JsonKey(name: 'courier_other') String? courierOther,

    /// Uppercase-forced in the mockup, and worth keeping — a waybill is quoted over the phone.
    String? waybill,
    @JsonKey(name: 'from_partner') String? fromPartner,
    @JsonKey(name: 'to_partner') String? toPartner,
    @JsonKey(name: 'to_address') @Default(<String, dynamic>{}) Map<String, dynamic> toAddress,

    /// Minor units, paired with this leg's own currency — an international leg may be declared
    /// in a different currency from the job.
    @JsonKey(name: 'declared_value') int? declaredValueMinor,
    @Default('INR') String currency,
    @Default(true) bool insured,

    /// The mockup offered an international courier with no customs fields at all.
    @JsonKey(name: 'is_international') @Default(false) bool isInternational,
    @JsonKey(name: 'customs_ref') String? customsRef,
    @JsonKey(name: 'commercial_inv') String? commercialInv,
    @JsonKey(name: 'signature_req') @Default(true) bool signatureReq,

    /// 'Requires white-glove unboxing prep.'
    @JsonKey(name: 'white_glove') @Default(false) bool whiteGlove,
    @JsonKey(name: 'dispatched_at') DateTime? dispatchedAt,
    @JsonKey(name: 'delivered_at') DateTime? deliveredAt,
    @JsonKey(name: 'pod_id') String? podId,
    @JsonKey(name: 'received_by') String? receivedBy,
    @JsonKey(name: 'created_at') required DateTime createdAt,

    /// Hydrated by a nested select. Not written back — checks are their own rows.
    @JsonKey(name: 'shipment_checks', includeToJson: false)
    @Default(<ShipmentCheck>[])
    List<ShipmentCheck> checks,
  }) = _Shipment;

  factory Shipment.fromJson(Map<String, dynamic> json) => _$ShipmentFromJson(json);

  Money? get declaredValue =>
      declaredValueMinor == null ? null : Money(declaredValueMinor!, currency);

  List<ShipmentCheck> get orderedChecks =>
      checks.sorted((a, b) => a.position.compareTo(b.position));

  int get passedCheckCount => checks.where((c) => c.passed).length;

  /// '3/3' — the security protocol counter.
  String get checkProgressLabel => '$passedCheckCount/${checks.length}';

  /// Every seal and count confirmed.
  bool get isSecurityComplete => checks.isNotEmpty && checks.every((c) => c.passed);

  /// An international leg needs both a customs reference and a commercial invoice. The mockup's
  /// courier list included Malca-Amit and had a field for neither.
  bool get needsCustomsPaperwork {
    if (!isInternational) return false;
    final hasCustomsRef = customsRef?.trim().isNotEmpty ?? false;
    return !hasCustomsRef || commercialInv == null;
  }

  /// The real dispatch gate. The mockup's version was cosmetic: its JavaScript toggled opacity
  /// classes and never set `.disabled`, so "Confirm Dispatch" fired with the tamper-seal
  /// protocol incomplete. Bind `onPressed` to this; `fn_dispatch_shipment` re-checks it.
  bool get canDispatch =>
      status.isDispatchable && isSecurityComplete && !needsCustomsPaperwork;

  /// Why dispatch is held shut, in the order the operator should fix it.
  String? get dispatchBlockedReason {
    if (!status.isDispatchable) return null;
    if (checks.isEmpty) {
      return 'No security protocol has been generated for this leg yet.';
    }
    if (!isSecurityComplete) {
      final open = checks.length - passedCheckCount;
      return 'Complete the security protocol: $open step${open == 1 ? '' : 's'} left.';
    }
    if (needsCustomsPaperwork) {
      return 'An international leg needs a customs reference and a commercial invoice.';
    }
    return null;
  }

  /// 'Brinks Secure Logistics' / the typed name behind 'Other'.
  String get courierLabel {
    final c = courier;
    if (c == null) return '—';
    if (c == Courier.other) {
      final named = courierOther?.trim();
      return named == null || named.isEmpty ? 'Other' : named;
    }
    return c.label;
  }

  /// Direct-to-customer requires white-glove unboxing prep, which the mockup stated and never
  /// carried into the record.
  bool get whiteGloveMismatch =>
      (routing?.needsWhiteGlove ?? false) && !whiteGlove;

  bool get isDelivered => status == ShipmentStatus.delivered;

  /// Delivered with nothing signed for is an undocumented handover of a high-value piece.
  bool get needsProofOfDelivery => isDelivered && podId == null;

  Duration? get transitTime {
    final from = dispatchedAt;
    if (from == null) return null;
    return (deliveredAt ?? DateTime.now()).toUtc().difference(from.toUtc());
  }
}

/// `shipment_checks` — one step of the tamper-seal protocol. 'Tamper-evident seal applied to
/// inner box', reference 'Seal #TE-921'.
@freezed
class ShipmentCheck with _$ShipmentCheck {
  const ShipmentCheck._();

  const factory ShipmentCheck({
    required String id,
    @JsonKey(name: 'shipment_id') required String shipmentId,
    required int position,
    required String label,

    /// 'Seal #TE-921' — the serial that makes the check auditable rather than a tick.
    String? reference,
    @Default(false) bool passed,
    @JsonKey(name: 'checked_by') String? checkedBy,
    @JsonKey(name: 'checked_at') DateTime? checkedAt,
  }) = _ShipmentCheck;

  factory ShipmentCheck.fromJson(Map<String, dynamic> json) => _$ShipmentCheckFromJson(json);

  bool get hasReference => reference?.trim().isNotEmpty ?? false;

  /// A passed seal step with no serial recorded cannot be verified later.
  bool get needsReference => passed && !hasReference;
}
