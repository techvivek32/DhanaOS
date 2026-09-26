/// The specification tables the intake wizard fills: `product_specs`, `metal_specs`, `stones`,
/// `melee_parcels`, `delivery_schedules`, `acceptance_criteria`, `requirements` and
/// `job_references`.
///
/// Every write here is **autosave-shaped**. The wizard calls one method per field the operator
/// touches, so each method takes a partial built from [Opt] and is safe to fire on a debounce.
/// The one-row-per-job tables are upserted rather than inserted-then-updated, because a wizard
/// step is reachable before its row exists and PostgREST's merge-duplicates only writes the
/// columns present in the body.
///
/// Three things in this file are not plumbing:
///
///  * **`stones.origin` is never dropped.** It survived in exactly one of 46 mockups (D-012).
///    [addStone] takes it, [updateStone] writes it, and `Stone.openQuestions` lists it as an
///    unanswered question until it is set. Natural versus lab-grown changes valuation,
///    disclosure and certification.
///  * **Custody is complete or it is not recorded.** [recordCustody] requires declared value,
///    verifier, timestamp, receipt code and the risk acknowledgement together — the mockups had
///    a "Verified & Logged in Inventory" chip and captured none of them.
///  * **The certification buffer follows the lab.** Choosing no lab zeroes
///    `delivery_schedules.cert_buffer_d`. That cross-screen dependency was declared in the
///    mockups' own comments and never wired; [upsertAcceptance] wires it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'spec_repository.g.dart';

// ================================================================= gates

/// D-011 rule 4, extended. Intake cannot advance past media capture without a reference — and a
/// reference is a photo **or** a voice note **or** an uploaded file, not the camera-only gate the
/// mockup shipped.
final class CaptureGate {
  const CaptureGate({
    required this.references,
    required this.photos,
    required this.voiceNotes,
    required this.files,
  });

  /// `job_references` rows that actually point at a file. A note on its own is not a reference.
  final List<JobReference> references;

  /// `reference_image` and `sketch` attachments — the camera path.
  final List<Attachment> photos;

  /// `voice_note` attachments. The mockup printed a hardcoded "01:20" duration; these carry the
  /// figure the recorder reported.
  final List<Attachment> voiceNotes;

  /// Anything else uploaded as a reference — a PDF from the retailer, a scan, an STL.
  final List<Attachment> files;

  int get evidenceCount =>
      references.where((r) => r.hasFile).length +
      photos.length +
      voiceNotes.length +
      files.length;

  bool get isSatisfied => evidenceCount > 0;

  /// What to put under a disabled Continue button. Convention 8: it says what is missing and
  /// what satisfies it.
  String? get blockReason => isSatisfied
      ? null
      : 'Capture at least one reference before continuing — a photo, a voice note, '
          'or an uploaded sketch.';

  /// 'Photo · Voice note' — which kinds of evidence are on file.
  String get evidenceLabel {
    final parts = <String>[
      if (photos.isNotEmpty) '${photos.length} photo${photos.length == 1 ? '' : 's'}',
      if (voiceNotes.isNotEmpty)
        '${voiceNotes.length} voice note${voiceNotes.length == 1 ? '' : 's'}',
      if (files.isNotEmpty) '${files.length} file${files.length == 1 ? '' : 's'}',
    ];
    return parts.isEmpty ? 'Nothing captured yet' : parts.join(' · ');
  }
}

/// What one stone still needs before it is a buildable specification.
///
/// Built from `Stone.openQuestions` and `Stone.missingCustodyFields`, so the rule lives on the
/// model and this only names which stone it applies to.
final class StoneGap {
  const StoneGap({
    required this.stoneId,
    required this.label,
    required this.missing,
    required this.custodyMissing,
  });

  final String stoneId;

  /// 'Centre Stone · Diamond'.
  final String label;

  /// Everything unanswered, custody included.
  final List<String> missing;

  /// The custody subset, so the custody card can be highlighted on its own. Non-empty only for a
  /// client-supplied stone.
  final List<String> custodyMissing;

  bool get isSatisfied => missing.isEmpty;

  bool get needsCustody => custodyMissing.isNotEmpty;

  /// 'Centre Stone · Diamond: Origin (Natural / Lab Grown), Shape'
  String get summary => '$label: ${missing.join(', ')}';
}

// ================================================================= repository

/// `REQ-<3 letter domain>-<2 digit seq>`, enforced by `req_code_shape` in SQL. Checked here too
/// so a bad code reads as a typo rather than as a constraint violation.
final _reqCodeShape = RegExp(r'^REQ-[A-Z]{3}-[0-9]{2}$');

/// The five requirement codes the mockups carried, all on one screen. D-009 makes them rows so
/// shop floor, QC and customer cite `REQ-MAT-01` instead of arguing about "the metal thing".
const _reqBaseMetal = 'REQ-MAT-01';
const _reqPurity = 'REQ-PUR-02';
const _reqGemstoneInset = 'REQ-GEM-03';
const _reqTargetBudget = 'REQ-FIN-04';
const _reqDeliveryTarget = 'REQ-TML-05';

final class SpecRepository {
  const SpecRepository(this._client, this._identity);

  final SupabaseClient _client;
  final RepoIdentity _identity;

  // ---------------------------------------------------------------- product spec

  Future<ProductSpec?> getProductSpec(String jobId) async {
    final row = await guardOrNull(
      () => _client.from('product_specs').select().eq('job_id', jobId).maybeSingle(),
    );
    return row == null ? null : ProductSpec.fromJson(row);
  }

  /// D-012: `engagement_ring_specs_expanded` is canonical, and the ring-only dimension fields the
  /// mockups hardcoded are joined here by the non-ring ones — a necklace stores a length, a
  /// bangle an inner diameter.
  ///
  /// India sizing is primary for this market; US and UK are stored alongside because customers
  /// arrive quoting any of the three.
  Future<ProductSpec> upsertProductSpec(
    String jobId, {
    Opt<SettingStyle>? settingStyle,
    Opt<String>? settingDetail,
    Opt<MetalFinish>? metalFinish,
    Opt<BandProfile>? bandProfile,
    Opt<FitProfile>? fit,
    Opt<SideStoneSetting>? sideStones,
    Opt<DesignIntent>? designIntent,
    Opt<String>? designIntentNote,
    Opt<double>? ringSizeIn,
    Opt<double>? ringSizeUs,
    Opt<String>? ringSizeUk,
    Opt<double>? bandWidthMm,
    Opt<double>? lengthMm,
    Opt<double>? innerDiaMm,
    Opt<double>? dropMm,
    Opt<String>? notes,
  }) async {
    final payload = <String, Object?>{'job_id': jobId};
    writeOpt(payload, 'setting_style', settingStyle, (v) => v.wire);
    writeOpt(payload, 'setting_detail', settingDetail, (v) => v.trim());
    writeOpt(payload, 'metal_finish', metalFinish, (v) => v.wire);
    writeOpt(payload, 'band_profile', bandProfile, (v) => v.wire);
    writeOpt(payload, 'fit', fit, (v) => v.wire);
    writeOpt(payload, 'side_stones', sideStones, (v) => v.wire);
    writeOpt(payload, 'design_intent', designIntent, (v) => v.wire);
    writeOpt(payload, 'design_intent_note', designIntentNote, (v) => v.trim());
    writeOpt(payload, 'ring_size_in', ringSizeIn);
    writeOpt(payload, 'ring_size_us', ringSizeUs);
    writeOpt(payload, 'ring_size_uk', ringSizeUk, (v) => v.trim().toUpperCase());
    writeOpt(payload, 'band_width_mm', bandWidthMm);
    writeOpt(payload, 'length_mm', lengthMm);
    writeOpt(payload, 'inner_dia_mm', innerDiaMm);
    writeOpt(payload, 'drop_mm', dropMm);
    writeOpt(payload, 'notes', notes, (v) => v.trim());

    final row = await guard(
      () => _client
          .from('product_specs')
          .upsert(payload, onConflict: 'job_id')
          .select()
          .single(),
    );
    return ProductSpec.fromJson(row);
  }

  // ---------------------------------------------------------------- metal spec

  Future<MetalSpec?> getMetalSpec(String jobId) async {
    final row = await guardOrNull(
      () => _client.from('metal_specs').select().eq('job_id', jobId).maybeSingle(),
    );
    return row == null ? null : MetalSpec.fromJson(row);
  }

  /// D-012: the union of `metal_materials` and `quick_specs`, which were two screens for one step
  /// with disjoint field sets rather than iterations of each other.
  ///
  /// The purity/base-metal dependency is validated rather than assumed: the mockups shipped a
  /// flat purity list, so 22K rose gold was selectable and that is not a product. `REQ-FIN-04`
  /// budgets are [Money] in the job's own currency — D-004 forbids a bare int in this path, and
  /// a budget typed in USD against an INR job would be an eighty-fold error stored silently.
  Future<MetalSpec> upsertMetalSpec(
    String jobId, {
    Opt<BaseMetal>? baseMetal,
    Opt<MetalPurity>? purity,
    Opt<MetalColor>? color,
    Opt<double>? targetWeightG,
    Opt<double>? weightTolG,
    Opt<bool>? customerSupplied,
    Opt<String>? hallmark,
    Opt<String>? alloyNotes,
    Opt<bool>? gemstoneInset,
    Opt<Money>? targetBudgetMin,
    Opt<Money>? targetBudgetMax,
  }) async {
    final strandedPurity = await _reconcilePurity(jobId, baseMetal: baseMetal, purity: purity);

    final payload = <String, Object?>{'job_id': jobId};
    writeOpt(payload, 'base_metal', baseMetal, (v) => v.wire);
    writeOpt(payload, 'purity', purity, (v) => v.wire);
    // Switching platinum to gold leaves Pt 950 behind. Clearing it is right — refusing the metal
    // change would make the operator undo the purity first to change the thing above it.
    if (strandedPurity) payload['purity'] = null;
    writeOpt(payload, 'color', color, (v) => v.wire);
    writeOpt(payload, 'target_weight_g', targetWeightG);
    writeOpt(payload, 'weight_tol_g', weightTolG);
    writeOpt(payload, 'customer_supplied', customerSupplied);
    writeOpt(payload, 'hallmark', hallmark, (v) => v.trim());
    writeOpt(payload, 'alloy_notes', alloyNotes, (v) => v.trim());
    writeOpt(payload, 'gemstone_inset', gemstoneInset);

    // The currency is only worth a round trip when a figure is actually being written; clearing a
    // budget needs no check. `currency!` is unreachable unless one of the two carried a value.
    final needsCurrency = targetBudgetMin?.value != null || targetBudgetMax?.value != null;
    final currency = needsCurrency ? await _jobCurrency(jobId) : null;
    writeOpt(
      payload,
      'target_budget_min',
      targetBudgetMin,
      (v) => _minorIn(v, currency!, 'target budget'),
    );
    writeOpt(
      payload,
      'target_budget_max',
      targetBudgetMax,
      (v) => _minorIn(v, currency!, 'target budget'),
    );

    final row = await guard(
      () => _client.from('metal_specs').upsert(payload, onConflict: 'job_id').select().single(),
    );
    return MetalSpec.fromJson(row);
  }

  /// The purity/base-metal dependency the mockups declared and never enforced, checked against the
  /// pair that will exist *after* this write.
  ///
  /// The two directions are not symmetrical. Picking 22K on a platinum job is a mistake and is
  /// refused with the list of purities that would work. Switching the base metal while a purity is
  /// already stored is not a mistake — it just strands the old grade — so this reports that the
  /// stored value has to be cleared and the caller clears it.
  ///
  /// Returns true when the stored purity no longer fits the metal being written.
  Future<bool> _reconcilePurity(
    String jobId, {
    Opt<BaseMetal>? baseMetal,
    Opt<MetalPurity>? purity,
  }) async {
    if (baseMetal == null && purity == null) return false;

    final existing = await getMetalSpec(jobId);
    final metal = baseMetal == null ? existing?.baseMetal : baseMetal.value;
    if (metal == null) return false;

    final chosen = purity?.value;
    if (chosen != null) {
      if (metal.purities.contains(chosen)) return false;
      throw MissingRequiredField(
        message: '${chosen.label} is not a ${metal.label.toLowerCase()} purity. '
            'Choose one of ${[for (final p in metal.purities) p.label].join(', ')}.',
        code: 'purity_metal_mismatch',
      );
    }

    // This write carries no purity. If the caller is clearing it, there is nothing to strand.
    if (purity != null) return false;
    final stored = existing?.purity;
    return stored != null && !metal.purities.contains(stored);
  }

  // ---------------------------------------------------------------- stones

  Future<List<Stone>> listStones(String jobId) async {
    final rows = await guard(
      () => _client
          .from('stones')
          .select()
          .eq('job_id', jobId)
          // stone_role is declared center < accent < side, so this is centre stone first.
          .order('role', ascending: true)
          .order('position', ascending: true),
    );
    return [for (final row in rows) Stone.fromJson(row)];
  }

  Future<Stone> getStone(String stoneId) async {
    final row = await guardOrNull(
      () => _client.from('stones').select().eq('id', stoneId).maybeSingle(),
    );
    if (row == null) {
      throw RecordNotFound(
        message: 'That stone is no longer on this job.',
        detail: 'stones.id=$stoneId',
        code: 'PGRST116',
      );
    }
    return Stone.fromJson(row);
  }

  /// Add a stone to the job.
  ///
  /// D-012: [origin] is offered at creation because every redesign after the first dropped it and
  /// the field decides valuation, disclosure and certification. It stays nullable in SQL, but a
  /// stone without it is reported as incomplete by `Stone.openQuestions`.
  Future<Stone> addStone({
    required String jobId,
    StoneRole role = StoneRole.center,
    StoneSourcing sourcing = StoneSourcing.needsSourcing,
    StoneType? stoneType,
    StoneOrigin? origin,
    StoneShape? shape,
    double? carat,
    int? position,
  }) async {
    final slot = position ?? await _nextStonePosition(jobId, role);
    final row = await guard(
      () => _client
          .from('stones')
          .insert({
            'job_id': jobId,
            'role': role.wire,
            'position': slot,
            'sourcing': sourcing.wire,
            'stone_type': stoneType?.wire,
            'origin': origin?.wire,
            'shape': shape?.wire,
            'carat': carat,
          })
          .select()
          .single(),
    );
    return Stone.fromJson(row);
  }

  Future<int> _nextStonePosition(String jobId, StoneRole role) async {
    final rows = await guard(
      () => _client
          .from('stones')
          .select('position')
          .eq('job_id', jobId)
          .eq('role', role.wire)
          .order('position', ascending: false)
          .limit(1),
    );
    if (rows.isEmpty) return 0;
    final highest = rows.first['position'] as int?;
    return highest == null ? 0 : highest + 1;
  }

  /// Autosave for one stone. Every field the seven mockup variants made editable in some
  /// combination or other is here, because D-012 resolved them to a union rather than to whichever
  /// redesign came last.
  Future<Stone> updateStone(
    String stoneId, {
    Opt<StoneRole>? role,
    Opt<int>? position,
    Opt<StoneSourcing>? sourcing,
    Opt<StoneType>? stoneType,
    Opt<StoneOrigin>? origin,
    Opt<StoneShape>? shape,
    Opt<double>? carat,
    Opt<double>? lengthMm,
    Opt<double>? widthMm,
    Opt<double>? depthMm,
    Opt<DiamondColor>? color,
    Opt<String>? colorRange,
    Opt<DiamondClarity>? clarity,
    Opt<String>? clarityRange,
    Opt<DiamondCut>? cut,
    Opt<String>? treatment,
    Opt<String>? provenance,
    Opt<bool>? certRequired,
    Opt<CertLab>? certLab,
    Opt<String>? certNumber,
    Opt<String>? certAttachment,
    Opt<String>? photoAttachment,
    Opt<String>? inventoryItemId,
    Opt<String>? notes,
  }) async {
    final payload = <String, Object?>{};
    writeOpt(payload, 'role', role, (v) => v.wire);
    writeOpt(payload, 'position', position);
    writeOpt(payload, 'sourcing', sourcing, (v) => v.wire);
    writeOpt(payload, 'stone_type', stoneType, (v) => v.wire);
    writeOpt(payload, 'origin', origin, (v) => v.wire);
    writeOpt(payload, 'shape', shape, (v) => v.wire);
    writeOpt(payload, 'carat', carat);
    writeOpt(payload, 'length_mm', lengthMm);
    writeOpt(payload, 'width_mm', widthMm);
    writeOpt(payload, 'depth_mm', depthMm);
    writeOpt(payload, 'color', color, (v) => v.wire);
    writeOpt(payload, 'color_range', colorRange, (v) => v.trim());
    writeOpt(payload, 'clarity', clarity, (v) => v.wire);
    writeOpt(payload, 'clarity_range', clarityRange, (v) => v.trim());
    writeOpt(payload, 'cut', cut, (v) => v.wire);
    writeOpt(payload, 'treatment', treatment, (v) => v.trim());
    writeOpt(payload, 'provenance', provenance, (v) => v.trim());
    writeOpt(payload, 'cert_required', certRequired);
    writeOpt(payload, 'cert_lab', certLab, (v) => v.wire);
    writeOpt(payload, 'cert_number', certNumber, (v) => v.trim());
    writeOpt(payload, 'cert_attachment', certAttachment);
    writeOpt(payload, 'photo_attachment', photoAttachment);
    writeOpt(payload, 'inventory_item_id', inventoryItemId);
    writeOpt(payload, 'notes', notes, (v) => v.trim());

    if (payload.isEmpty) return getStone(stoneId);

    final row = await guard(
      () => _client.from('stones').update(payload).eq('id', stoneId).select().single(),
    );
    return Stone.fromJson(row);
  }

  Future<void> deleteStone(String stoneId) =>
      guard(() => _client.from('stones').delete().eq('id', stoneId));

  /// Take custody of a client's own stone, completely or not at all.
  ///
  /// This is the gap the mockups left open: a `Reset Stone` job type, a "Verified & Logged in
  /// Inventory" chip, and no declared value, no verifier, no timestamp, no receipt and no risk
  /// acknowledgement anywhere. A shop that accepts a ₹10,00,000 diamond with no record of who
  /// took it and what it was worth carries that as legal and insurance exposure, so every field
  /// is required together and the risk acknowledgement must actually be given.
  /// [verifiedBy] defaults to the signed-in operator, because the verifier is whoever is putting
  /// their name to having seen the stone. D-008: that identity comes from the session and from
  /// nowhere else, so passing it explicitly is for the case where a manager records on behalf of
  /// a named colleague.
  Future<Stone> recordCustody({
    required String stoneId,
    required Money declaredValue,
    required String receiptCode,
    required bool riskAck,
    String? verifiedBy,
    DateTime? verifiedAt,
  }) async {
    final stone = await getStone(stoneId);
    if (!stone.isCustomerSupplied) {
      throw MissingRequiredField(
        message: 'Set this stone to Customer Supplied before recording custody — a '
            '${stone.sourcing.label.toLowerCase()} stone is not in your care.',
        code: 'custody_wrong_sourcing',
      );
    }
    if (declaredValue.isZero || declaredValue.isNegative) {
      throw const MissingRequiredField(
        message: 'Enter the value the client declares for this stone. It is what the '
            'insurance cover is written against.',
        code: 'custody_value_missing',
      );
    }
    final receipt = receiptCode.trim();
    if (receipt.isEmpty) {
      throw const MissingRequiredField(
        message: 'Enter the receipt number you gave the client for this stone.',
        code: 'custody_receipt_missing',
      );
    }
    if (!riskAck) {
      throw const MissingRequiredField(
        message: 'The client has to accept the risk terms before you take the stone. '
            'Tick the acknowledgement once they have.',
        code: 'custody_risk_unacknowledged',
      );
    }

    final currency = await _jobCurrency(stone.jobId);
    final row = await guard(
      () => _client
          .from('stones')
          .update({
            'declared_value': _minorIn(declaredValue, currency, 'declared value'),
            'verified_by': verifiedBy ?? _identity.requireUserId(),
            'verified_at': encodeInstant(verifiedAt ?? DateTime.now()),
            'receipt_code': receipt,
            'risk_ack': true,
          })
          .eq('id', stoneId)
          .select()
          .single(),
    );
    return Stone.fromJson(row);
  }

  /// Everything still unanswered across the job's stones, one entry per stone.
  ///
  /// The stone step passes when this is empty. Origin and the custody block are both in here, by
  /// way of `Stone.openQuestions`, which is where the rule belongs.
  Future<List<StoneGap>> stoneGaps(String jobId) async {
    final stones = await listStones(jobId);
    final gaps = <StoneGap>[];
    for (final stone in stones) {
      final missing = stone.openQuestions;
      if (missing.isEmpty) continue;
      gaps.add(
        StoneGap(
          stoneId: stone.id,
          label: stone.displayTitle,
          missing: List<String>.unmodifiable(missing),
          custodyMissing: List<String>.unmodifiable(stone.missingCustodyFields),
        ),
      );
    }
    return List<StoneGap>.unmodifiable(gaps);
  }

  // ---------------------------------------------------------------- melee

  Future<List<MeleeParcel>> listMelee(String jobId) async {
    final rows = await guard(
      () => _client
          .from('melee_parcels')
          .select()
          .eq('job_id', jobId)
          .order('created_at', ascending: true),
    );
    return [for (final row in rows) MeleeParcel.fromJson(row)];
  }

  /// A parcel is specified by a size band and a total weight, not by one measurement — which is
  /// what makes "Melee diamonds count mismatch at receiving" checkable instead of decorative.
  Future<MeleeParcel> addMelee({
    required String jobId,
    StoneType stoneType = StoneType.diamond,
    StoneShape shape = StoneShape.roundBrilliant,
    StoneSourcing sourcing = StoneSourcing.needsSourcing,
    StoneOrigin? origin,
    double? sizeMinMm,
    double? sizeMaxMm,
    double? totalCtw,
    int? pieceCount,
  }) async {
    final row = await guard(
      () => _client
          .from('melee_parcels')
          .insert({
            'job_id': jobId,
            'stone_type': stoneType.wire,
            'shape': shape.wire,
            'sourcing': sourcing.wire,
            'origin': origin?.wire,
            'size_min_mm': sizeMinMm,
            'size_max_mm': sizeMaxMm,
            'total_ctw': totalCtw,
            'piece_count': pieceCount,
          })
          .select()
          .single(),
    );
    return MeleeParcel.fromJson(row);
  }

  Future<MeleeParcel> updateMelee(
    String parcelId, {
    Opt<StoneSourcing>? sourcing,
    Opt<StoneType>? stoneType,
    Opt<StoneOrigin>? origin,
    Opt<StoneShape>? shape,
    Opt<double>? sizeMinMm,
    Opt<double>? sizeMaxMm,
    Opt<double>? totalCtw,
    Opt<int>? pieceCount,
    Opt<String>? colorRange,
    Opt<String>? clarityRange,
    Opt<String>? notes,
  }) async {
    final payload = <String, Object?>{};
    writeOpt(payload, 'sourcing', sourcing, (v) => v.wire);
    writeOpt(payload, 'stone_type', stoneType, (v) => v.wire);
    writeOpt(payload, 'origin', origin, (v) => v.wire);
    writeOpt(payload, 'shape', shape, (v) => v.wire);
    writeOpt(payload, 'size_min_mm', sizeMinMm);
    writeOpt(payload, 'size_max_mm', sizeMaxMm);
    writeOpt(payload, 'total_ctw', totalCtw);
    writeOpt(payload, 'piece_count', pieceCount);
    writeOpt(payload, 'color_range', colorRange, (v) => v.trim());
    writeOpt(payload, 'clarity_range', clarityRange, (v) => v.trim());
    writeOpt(payload, 'notes', notes, (v) => v.trim());

    final row = await guard(
      () => _client.from('melee_parcels').update(payload).eq('id', parcelId).select().single(),
    );
    return MeleeParcel.fromJson(row);
  }

  Future<void> deleteMelee(String parcelId) =>
      guard(() => _client.from('melee_parcels').delete().eq('id', parcelId));

  // ---------------------------------------------------------------- delivery

  Future<DeliverySchedule?> getDelivery(String jobId) async {
    final row = await guardOrNull(
      () => _client.from('delivery_schedules').select().eq('job_id', jobId).maybeSingle(),
    );
    return row == null ? null : DeliverySchedule.fromJson(row);
  }

  /// The buffers between "done on the bench" and "in the customer's hand".
  ///
  /// The mockup hardcoded both as constants that never varied with priority, with its own source
  /// carrying the comment "Could adjust buffers here based on priority". Passing
  /// `applyPriorityBuffer: true` does what that comment intended — a rush job gets less slack in
  /// the plan, not a faster courier.
  Future<DeliverySchedule> upsertDelivery(
    String jobId, {
    Opt<DateTime>? requestedDate,
    Opt<bool>? hardDeadline,
    Opt<bool>? partialAllowed,
    Opt<Priority>? priority,
    Opt<int>? dispatchBufferD,
    Opt<int>? certBufferD,
    Opt<DateTime>? recommendedDone,
    bool applyPriorityBuffer = false,
  }) async {
    final payload = <String, Object?>{'job_id': jobId};
    writeOpt(payload, 'requested_date', requestedDate, encodeDate);
    writeOpt(payload, 'hard_deadline', hardDeadline);
    writeOpt(payload, 'partial_allowed', partialAllowed);
    writeOpt(payload, 'priority', priority, (v) => v.wire);
    writeOpt(payload, 'dispatch_buffer_d', dispatchBufferD);
    writeOpt(payload, 'cert_buffer_d', certBufferD);
    writeOpt(payload, 'recommended_done', recommendedDone, encodeDate);

    final chosen = priority?.value;
    if (applyPriorityBuffer && chosen != null && dispatchBufferD == null) {
      // Mirrors DeliverySchedule.recommendedDispatchBuffer, which is where the figures live; an
      // explicit dispatchBufferD always wins, so an operator's own number is never overwritten.
      payload['dispatch_buffer_d'] = switch (chosen) {
        Priority.standard => 2,
        Priority.rush || Priority.critical => 1,
      };
    }

    final row = await guard(
      () => _client
          .from('delivery_schedules')
          .upsert(payload, onConflict: 'job_id')
          .select()
          .single(),
    );
    return DeliverySchedule.fromJson(row);
  }

  // ---------------------------------------------------------------- acceptance

  Future<AcceptanceCriteria?> getAcceptance(String jobId) async {
    final row = await guardOrNull(
      () => _client.from('acceptance_criteria').select().eq('job_id', jobId).maybeSingle(),
    );
    return row == null ? null : AcceptanceCriteria.fromJson(row);
  }

  /// What the piece is measured against at QC, agreed up front.
  ///
  /// Writing [certLab] also carries the cross-screen dependency the mockups declared and never
  /// wired: `CertLab.none` skips the certification stage, so the certification buffer in
  /// `delivery_schedules` has to go to zero, and choosing a real lab again has to put it back.
  Future<AcceptanceCriteria> upsertAcceptance(
    String jobId, {
    Opt<bool>? matchCad,
    Opt<bool>? highPolish,
    Opt<bool>? sizeWeightConform,
    Opt<bool>? strictTolerance,
    Opt<double>? toleranceMm,
    Opt<bool>? stonesSecure,
    Opt<bool>? symmetry,
    Opt<CertLab>? certLab,
    Opt<String>? certLabOther,
    Opt<QualityAuthority>? authority,
    Opt<String>? customerNotes,
  }) async {
    final payload = <String, Object?>{'job_id': jobId};
    writeOpt(payload, 'match_cad', matchCad);
    writeOpt(payload, 'high_polish', highPolish);
    writeOpt(payload, 'size_weight_conform', sizeWeightConform);
    writeOpt(payload, 'strict_tolerance', strictTolerance);
    writeOpt(payload, 'tolerance_mm', toleranceMm);
    writeOpt(payload, 'stones_secure', stonesSecure);
    writeOpt(payload, 'symmetry', symmetry);
    writeOpt(payload, 'cert_lab', certLab, (v) => v.wire);
    writeOpt(payload, 'cert_lab_other', certLabOther, (v) => v.trim());
    writeOpt(payload, 'authority', authority, (v) => v.wire);
    writeOpt(payload, 'customer_notes', customerNotes, (v) => v.trim());

    final row = await guard(
      () => _client
          .from('acceptance_criteria')
          .upsert(payload, onConflict: 'job_id')
          .select()
          .single(),
    );
    final saved = AcceptanceCriteria.fromJson(row);

    final lab = certLab?.value;
    if (lab != null) await _syncCertBuffer(jobId, lab);

    return saved;
  }

  /// `delivery_schedules.cert_buffer_d` must be zero when no lab will see the piece.
  ///
  /// Going the other way only restores the three-day default when the buffer is currently zero —
  /// an operator who deliberately set five days keeps them.
  Future<void> _syncCertBuffer(String jobId, CertLab lab) async {
    if (lab.skipsStage) {
      await upsertDelivery(jobId, certBufferD: const Opt(0));
      return;
    }
    final delivery = await getDelivery(jobId);
    if (delivery != null && delivery.certBufferD == 0) {
      await upsertDelivery(jobId, certBufferD: const Opt(3));
    }
  }

  // ---------------------------------------------------------------- requirements (D-009)

  Future<List<Requirement>> listRequirements(String jobId) async {
    final rows = await guard(
      () => _client
          .from('requirements')
          .select()
          .eq('job_id', jobId)
          .order('code', ascending: true),
    );
    return [for (final row in rows) Requirement.fromJson(row)];
  }

  Future<Requirement> upsertRequirement({
    required String jobId,
    required String code,
    required String domain,
    required String label,
    String? valueText,
    bool isCritical = false,
    String? sourceField,
  }) async {
    if (!_reqCodeShape.hasMatch(code)) {
      throw MissingRequiredField(
        message: 'A requirement code looks like REQ-MAT-01 — three letters, two digits. '
            'Got "$code".',
        code: 'req_code_shape',
      );
    }
    final row = await guard(
      () => _client
          .from('requirements')
          .upsert({
            'job_id': jobId,
            'code': code,
            'domain': domain,
            'label': label,
            'value_text': valueText,
            'is_critical': isCritical,
            'source_field': sourceField,
          }, onConflict: 'job_id,code')
          .select()
          .single(),
    );
    return Requirement.fromJson(row);
  }

  Future<void> deleteRequirement(String requirementId) =>
      guard(() => _client.from('requirements').delete().eq('id', requirementId));

  /// Rewrite the five requirement rows the specification derives, so shop floor, QC and customer
  /// share one citation for each.
  ///
  /// These are the exact five codes the mockups carried on a single screen; D-009 makes them
  /// rows. Values are written even when unanswered — a citation reading `REQ-PUR-02 · Alloy
  /// Purity` with nothing after it is a visible gap, which is the point.
  ///
  /// Call this when a spec step is left, not on every keystroke.
  Future<List<Requirement>> syncCoreRequirements(String jobId) async {
    final job = await _getJob(jobId);
    final metal = await getMetalSpec(jobId);
    final delivery = await getDelivery(jobId);

    final hasBudget =
        metal != null && (metal.targetBudgetMinMinor != null || metal.targetBudgetMaxMinor != null);
    final budget = hasBudget ? metal.budgetLabel(job.currency) : null;
    final target = delivery?.requestedDate ?? job.requestedDelivery;

    final rows = <Map<String, Object?>>[
      _requirementRow(
        jobId: jobId,
        code: _reqBaseMetal,
        domain: 'MAT',
        label: 'Base Metal',
        value: metal?.baseMetal?.label,
        sourceField: 'metal_specs.base_metal',
        isCritical: true,
      ),
      _requirementRow(
        jobId: jobId,
        code: _reqPurity,
        domain: 'PUR',
        label: 'Alloy Purity',
        value: metal?.purity?.label,
        sourceField: 'metal_specs.purity',
        isCritical: true,
      ),
      _requirementRow(
        jobId: jobId,
        code: _reqGemstoneInset,
        domain: 'GEM',
        label: 'Gemstone Inset',
        // REQ-GEM-03: an explicit No skips the stone step. Null is "not answered yet", which is
        // not the same answer and must not read as one.
        value: switch (metal?.gemstoneInset) {
          true => 'Yes',
          false => 'No',
          null => null,
        },
        sourceField: 'metal_specs.gemstone_inset',
      ),
      _requirementRow(
        jobId: jobId,
        code: _reqTargetBudget,
        domain: 'FIN',
        label: 'Target Budget',
        value: budget,
        sourceField: 'metal_specs.target_budget_min',
      ),
      _requirementRow(
        jobId: jobId,
        code: _reqDeliveryTarget,
        domain: 'TML',
        label: 'Delivery Target',
        value: target == null ? null : encodeDate(target),
        sourceField: 'delivery_schedules.requested_date',
        isCritical: true,
      ),
    ];

    final saved = await guard(
      () => _client.from('requirements').upsert(rows, onConflict: 'job_id,code').select(),
    );
    return [for (final row in saved) Requirement.fromJson(row)];
  }

  static Map<String, Object?> _requirementRow({
    required String jobId,
    required String code,
    required String domain,
    required String label,
    required String? value,
    required String sourceField,
    bool isCritical = false,
  }) =>
      {
        'job_id': jobId,
        'code': code,
        'domain': domain,
        'label': label,
        'value_text': value,
        'is_critical': isCritical,
        'source_field': sourceField,
      };

  // ---------------------------------------------------------------- references (D-011 rule 4)

  Future<List<JobReference>> listReferences(String jobId) async {
    final rows = await guard(
      () => _client
          .from('job_references')
          .select()
          .eq('job_id', jobId)
          .order('is_primary', ascending: false)
          .order('created_at', ascending: true),
    );
    return [for (final row in rows) JobReference.fromJson(row)];
  }

  /// Record a captured reference against the job.
  ///
  /// D-001: the reference code is `RF-<4 digit>`, minted per job from the highest one already
  /// there. `job_references` has no unique index on it, so this is a readable sequence rather
  /// than an identifier anything joins on.
  Future<JobReference> addReference({
    required String jobId,
    String? attachmentId,
    String? note,
    bool isPrimary = false,
    String? refCode,
  }) async {
    final existing = await listReferences(jobId);
    final code = refCode ?? _nextRefCode(existing);

    final row = await guard(
      () => _client
          .from('job_references')
          .insert({
            'job_id': jobId,
            'ref_code': code,
            'attachment_id': attachmentId,
            'note': note?.trim(),
            // The first reference on a job is the primary one unless told otherwise — a job with
            // references and no primary has nothing to show on a list row.
            'is_primary': isPrimary || existing.isEmpty,
          })
          .select()
          .single(),
    );
    return JobReference.fromJson(row);
  }

  /// Make one reference the primary and demote the rest. Two primaries would leave every list row
  /// picking a thumbnail arbitrarily.
  Future<JobReference> setPrimaryReference({
    required String jobId,
    required String referenceId,
  }) async {
    await guard(
      () => _client
          .from('job_references')
          .update({'is_primary': false})
          .eq('job_id', jobId)
          .neq('id', referenceId),
    );
    final row = await guard(
      () => _client
          .from('job_references')
          .update({'is_primary': true})
          .eq('id', referenceId)
          .select()
          .single(),
    );
    return JobReference.fromJson(row);
  }

  Future<void> deleteReference(String referenceId) =>
      guard(() => _client.from('job_references').delete().eq('id', referenceId));

  static String _nextRefCode(List<JobReference> existing) {
    var highest = 0;
    for (final ref in existing) {
      final code = ref.refCode;
      if (code == null || code.length < 4) continue;
      final value = int.tryParse(code.substring(3));
      if (value != null && value > highest) highest = value;
    }
    // The shape check allows four digits only, so the sequence wraps rather than overflowing it.
    final next = highest >= 9999 ? 1 : highest + 1;
    return 'RF-${next.toString().padLeft(4, '0')}';
  }

  /// D-011 rule 4, as the wizard needs to ask it: is there a reference yet, of any kind?
  ///
  /// The mockup's gate was camera-only. A voice note and an uploaded sketch satisfy it here,
  /// because a retailer describing a repair on the phone is a reference and refusing it sent
  /// operators to paper.
  Future<CaptureGate> captureGate(String jobId) async {
    final references = await listReferences(jobId);
    // Which kinds count is `Attachment.satisfiesCaptureGate`, on the model — so the rule has one
    // home. That means fetching the job's files and partitioning here rather than filtering by
    // kind in SQL, which would fork the rule into a second list that could drift.
    final rows = await guard(
      () => _client
          .from('attachments')
          .select()
          .eq('job_id', jobId)
          .order('created_at', ascending: true),
    );
    final counted = <Attachment>[];
    for (final row in rows) {
      final attachment = Attachment.fromJson(row);
      if (attachment.satisfiesCaptureGate) counted.add(attachment);
    }

    return CaptureGate(
      references: List<JobReference>.unmodifiable(references),
      photos: List<Attachment>.unmodifiable(
        counted.where((a) => !a.isVoiceNote && (a.isImage || a.kind == AttachmentKind.sketch)),
      ),
      voiceNotes: List<Attachment>.unmodifiable(counted.where((a) => a.isVoiceNote)),
      files: List<Attachment>.unmodifiable(
        counted.where((a) => !a.isVoiceNote && !a.isImage && a.kind != AttachmentKind.sketch),
      ),
    );
  }

  // ---------------------------------------------------------------- helpers

  /// The job's currency governs every money field hanging off it — `stones` and `metal_specs`
  /// carry no currency column of their own by design (D-004).
  Future<String> _jobCurrency(String jobId) async => (await _getJob(jobId)).currency;

  Future<Job> _getJob(String jobId) async {
    final row = await guardOrNull(
      () => _client
          .from('jobs')
          .select('id, org_id, currency, requested_delivery, created_at, updated_at')
          .eq('id', jobId)
          .maybeSingle(),
    );
    if (row == null) {
      throw RecordNotFound(
        message: 'That job is no longer there, or it is not yours to see.',
        detail: 'jobs.id=$jobId',
        code: 'PGRST116',
      );
    }
    return Job.fromJson(row);
  }

  /// D-004: minor units only cross the wire once the currency has been checked against the job.
  /// Storing 4850 paise as 4850 cents is a silent eighty-fold error, and it lands on a custody
  /// declaration or an insurance figure.
  static int _minorIn(Money amount, String currency, String field) {
    if (amount.currency == currency) return amount.minor;
    throw MissingRequiredField(
      message: 'This job is priced in $currency. Re-enter the $field in $currency.',
      detail: 'got ${amount.currency}, expected $currency',
      code: 'currency_mismatch',
    );
  }

  /// Kept so a caller can attribute a custody verification to the session user without reaching
  /// for the session itself. D-008: this is the only identity a repository will supply.
  String? get sessionUserId => _identity.userId;
}

// ================================================================= providers

@Riverpod(keepAlive: true)
SpecRepository specRepository(Ref ref) => SpecRepository(
      ref.watch(supabaseProvider),
      ref.watch(repoIdentityProvider),
    );

@riverpod
Future<ProductSpec?> productSpec(Ref ref, String jobId) =>
    ref.watch(specRepositoryProvider).getProductSpec(jobId);

@riverpod
Future<MetalSpec?> metalSpec(Ref ref, String jobId) =>
    ref.watch(specRepositoryProvider).getMetalSpec(jobId);

@riverpod
Future<List<Stone>> jobStones(Ref ref, String jobId) =>
    ref.watch(specRepositoryProvider).listStones(jobId);

@riverpod
Future<List<MeleeParcel>> jobMelee(Ref ref, String jobId) =>
    ref.watch(specRepositoryProvider).listMelee(jobId);

@riverpod
Future<DeliverySchedule?> deliverySchedule(Ref ref, String jobId) =>
    ref.watch(specRepositoryProvider).getDelivery(jobId);

@riverpod
Future<AcceptanceCriteria?> acceptanceCriteria(Ref ref, String jobId) =>
    ref.watch(specRepositoryProvider).getAcceptance(jobId);

@riverpod
Future<List<Requirement>> jobRequirements(Ref ref, String jobId) =>
    ref.watch(specRepositoryProvider).listRequirements(jobId);

/// D-011 rule 4. Watch this on the media step; the Continue button reads
/// `CaptureGate.isSatisfied` and the text under it reads `CaptureGate.blockReason`.
@riverpod
Future<CaptureGate> captureGate(Ref ref, String jobId) =>
    ref.watch(specRepositoryProvider).captureGate(jobId);

/// What the stone step still needs — origin and the custody block included.
@riverpod
Future<List<StoneGap>> stoneGaps(Ref ref, String jobId) =>
    ref.watch(specRepositoryProvider).stoneGaps(jobId);
