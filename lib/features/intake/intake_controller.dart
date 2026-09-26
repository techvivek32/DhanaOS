/// The engine behind the eleven steps: one draft, autosaved, resumable.
///
/// Three properties the mockups did not have, and which this file exists to provide:
///
///  * **The draft is real from step 1.** Choosing a job type inserts the `DRAFT-<4 char>` row
///    (D-001). Everything after it is an update to a row that already exists, so nothing is held
///    only in a widget's `State` where a phone call would lose it.
///  * **Every edit is written.** Discrete choices go immediately; typing is coalesced per field.
///    `Continue` flushes the queue before it moves, so a step is never left behind in a debounce.
///  * **The step is on the server too.** `jobs.wizard_step` is written on every move, which is
///    what makes a draft resumable on another device instead of only in this process.
///
/// Every mutating method returns `Future<String?>`: null when the write is on its way, otherwise
/// the sentence to show the operator. Failures from a *debounced* write land in
/// `IntakeDraft.saveError` and surface in the header badge, because there is no call site still
/// waiting by then.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/money.dart';
import 'package:dhanaos/data/repositories/customer_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/quote_repository.dart';
import 'package:dhanaos/data/repositories/spec_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/intake_gateway.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
import 'package:dhanaos/features/intake/save_queue.dart';
import 'package:dhanaos/features/intake/spec_edits.dart';

part 'intake_controller.g.dart';

/// Kept alive so leaving the wizard for a phone call and coming back lands on the same draft at
/// the same step rather than starting a second one.
@Riverpod(keepAlive: true)
class IntakeController extends _$IntakeController {
  final SaveQueue _queue = SaveQueue();
  bool _closed = false;

  @override
  Future<IntakeDraft> build(String? jobId) async {
    ref.onDispose(() {
      _closed = true;
      _queue.dispose();
    });

    final org = await ref.read(intakeGatewayProvider).org();
    if (jobId == null) return IntakeDraft(org: org);
    return _load(jobId, org: org);
  }

  // ================================================================ loading

  Future<IntakeDraft> _load(String id, {Org? org}) async {
    final jobs = ref.read(jobRepositoryProvider);
    final specs = ref.read(specRepositoryProvider);
    final quotes = ref.read(quoteRepositoryProvider);
    final files = ref.read(attachmentStoreProvider);
    final customers = ref.read(customerRepositoryProvider);

    final job = await jobs.getJob(id);

    // Fired together: a wizard resumed on shop Wi-Fi should not pay eleven round trips in series.
    final productSpec = specs.getProductSpec(id);
    final metalSpec = specs.getMetalSpec(id);
    final stones = specs.listStones(id);
    final melee = specs.listMelee(id);
    final delivery = specs.getDelivery(id);
    final acceptance = specs.getAcceptance(id);
    final references = specs.listReferences(id);
    final attachments = files.forJob(id);
    final quote = quotes.latestQuote(id);
    final gates = quotes.approvalGates(id);
    final customer = job.customerId == null
        ? Future<Customer?>.value()
        : customers.findCustomer(job.customerId!);
    final Future<StageRail?> rail =
        job.isCommitted ? jobs.getStageRail(id) : Future<StageRail?>.value();

    return IntakeDraft(
      job: job,
      org: org,
      customer: await customer,
      productSpec: await productSpec,
      metalSpec: await metalSpec,
      stones: await stones,
      melee: await melee,
      delivery: await delivery,
      acceptance: await acceptance,
      references: await references,
      attachments: await attachments,
      quote: await quote,
      gates: await gates,
      rail: await rail,
      step: IntakeStep.fromNumber(job.wizardStep),
    );
  }

  // ================================================================ plumbing

  IntakeDraft? get _draft => state.valueOrNull;

  void _patch(IntakeDraft Function(IntakeDraft current) apply) {
    final current = state.valueOrNull;
    if (current == null || _closed) return;
    state = AsyncData(apply(current));
  }

  void _mark(SaveState save, {String? error}) {
    _patch(
      (d) => d.copyWith(
        save: save,
        savedAt: save == SaveState.saved ? DateTime.now() : d.savedAt,
        saveError: save == SaveState.failed ? error : null,
      ),
    );
  }

  /// A write the operator is waiting on — an upload, a commit, a custody record.
  Future<String?> _act(Future<void> Function() body) async {
    _mark(SaveState.saving);
    try {
      await body();
      _mark(SaveState.saved);
      return null;
    } on DhFailure catch (failure) {
      _mark(SaveState.failed, error: failure.message);
      return failure.message;
    }
  }

  /// A write the operator is not waiting on. Coalesced under [key].
  void _save(
    String key,
    Future<void> Function(String jobId) write, {
    Duration delay = SaveDelay.immediate,
  }) {
    final id = _draft?.job?.id;
    if (id == null) return;
    _queue.schedule(key, delay, () async {
      _mark(SaveState.saving);
      try {
        await write(id);
        _mark(SaveState.saved);
      } on DhFailure catch (failure) {
        _mark(SaveState.failed, error: failure.message);
      }
    });
  }

  JobRepository get _jobs => ref.read(jobRepositoryProvider);
  SpecRepository get _specs => ref.read(specRepositoryProvider);
  QuoteRepository get _quotes => ref.read(quoteRepositoryProvider);
  AttachmentStore get _files => ref.read(attachmentStoreProvider);

  // ================================================================ navigation

  /// Move to [target], flushing anything still pending first.
  Future<String?> goTo(IntakeStep target) async {
    await _queue.flush();
    final current = _draft;
    if (current == null) return null;
    _patch((d) => d.copyWith(step: target));
    _save('job.step', (id) => _jobs.patchJob(id, wizardStep: Opt(target.number)));

    // Step entry work that has to have happened before the screen paints.
    if (target == IntakeStep.design) _seedProductSpec();
    if (target == IntakeStep.metal) _seedMetalSpec();
    if (target == IntakeStep.delivery) _seedDelivery();
    if (target == IntakeStep.quality) _seedAcceptance();
    if (target == IntakeStep.commercials) return ensureQuote();
    if (target == IntakeStep.review) return _prepareReview();
    return null;
  }

  Future<String?> advance() async {
    final current = _draft;
    if (current == null) return null;
    final next = current.nextAfter(current.step);
    if (next == null) return null;
    return goTo(next);
  }

  Future<String?> back() async {
    final current = _draft;
    if (current == null) return null;
    final previous = current.previousBefore(current.step);
    if (previous == null) return null;
    return goTo(previous);
  }

  // ================================================================ step 1 — job type

  /// Creates the draft on the first choice. D-001: `DRAFT-992A` until commit mints the real code.
  Future<String?> chooseJobType(JobType type) async {
    final current = _draft;
    if (current == null) return null;

    if (current.job == null) {
      return _act(() async {
        final job = await _jobs.createDraft(
          jobType: type,
          currency: current.org?.baseCurrency ?? 'INR',
        );
        _patch((d) => d.copyWith(job: job));
      });
    }

    _patch((d) => d.copyWith(job: d.job!.copyWith(jobType: type)));
    _save('job.type', (id) => _jobs.patchJob(id, jobType: Opt(type)));
    return null;
  }

  // ================================================================ step 2 — capture + header

  Future<String?> setTitle(String title) async {
    _patch((d) => d.copyWith(job: d.job?.copyWith(title: title)));
    _save(
      'job.title',
      (id) => _jobs.patchJob(id, title: Opt(title)),
      delay: SaveDelay.typing,
    );
    return null;
  }

  Future<String?> setCustomer(Customer customer) async {
    _patch(
      (d) => d.copyWith(
        customer: customer,
        job: d.job?.copyWith(customerId: customer.id),
      ),
    );
    _save('job.customer', (id) => _jobs.patchJob(id, customerId: Opt(customer.id)));
    return null;
  }

  Future<String?> setQuantity(int quantity) async {
    final safe = quantity < 1 ? 1 : quantity;
    _patch((d) => d.copyWith(job: d.job?.copyWith(quantity: safe)));
    _save('job.quantity', (id) => _jobs.patchJob(id, quantity: Opt(safe)));
    return null;
  }

  /// D-004. The manufacturer is an Indian entity, so INR is the default — but a US retailer's job
  /// is quoted in USD and every figure already captured has to move with it.
  Future<String?> setCurrency(String code) async {
    _patch((d) => d.copyWith(job: d.job?.copyWith(currency: code)));
    _save('job.currency', (id) => _jobs.patchJob(id, currency: Opt(code)));
    return null;
  }

  /// Upload a captured reference and file it as a `job_references` row so it earns an `RF-` code.
  /// D-011 rule 4: this is what opens the gate on step 2.
  Future<String?> addCapture({
    required AttachmentKind kind,
    required File file,
    String? filename,
    int? durationMs,
    String? caption,
  }) async {
    final job = _draft?.job;
    if (job == null) {
      return 'Choose a job type first — there is nothing to attach this to yet.';
    }
    return _act(() async {
      final attachment = await _files.upload(
        UploadRequest.file(
          orgId: job.orgId,
          kind: kind,
          file: file,
          filename: filename,
          jobId: job.id,
          durationMs: durationMs,
          caption: caption,
        ),
      );
      final reference = await _specs.addReference(
        jobId: job.id,
        attachmentId: attachment.id,
        note: caption,
      );
      _patch(
        (d) => d.copyWith(
          attachments: [...d.attachments, attachment],
          references: [...d.references, reference],
        ),
      );
    });
  }

  Future<String?> removeCapture(Attachment attachment) => _act(() async {
        final reference = _draft?.referenceFor(attachment);
        if (reference != null) await _specs.deleteReference(reference.id);
        await _files.delete(attachment);
        _patch(
          (d) => d.copyWith(
            attachments: [
              for (final a in d.attachments)
                if (a.id != attachment.id) a,
            ],
            references: [
              for (final r in d.references)
                if (r.attachmentId != attachment.id) r,
            ],
          ),
        );
      });

  Future<String?> makePrimaryReference(JobReference reference) {
    final job = _draft?.job;
    if (job == null) return Future.value(null);
    return _act(() async {
      await _specs.setPrimaryReference(jobId: job.id, referenceId: reference.id);
      _patch(
        (d) => d.copyWith(
          references: [
            for (final r in d.references)
              r.copyWith(isPrimary: r.id == reference.id),
          ],
        ),
      );
    });
  }

  // ================================================================ step 3 — category

  /// Changing the category changes which dimensions mean anything, so the sub-style and the
  /// ring-only fields go with it. D-012: the mockups hardcoded ring fields for every product.
  Future<String?> setCategory(ProductCategory category) async {
    final current = _draft;
    if (current == null) return null;

    final allowed = ProductSubStyle.forCategory(category);
    final keptStyle =
        current.subStyle != null && allowed.contains(current.subStyle) ? current.subStyle : null;

    _patch((d) => d.copyWith(job: d.job?.copyWith(category: category, subStyle: keptStyle)));
    _save(
      'job.category',
      (id) async {
        await _jobs.patchJob(
          id,
          category: Opt(category),
          subStyle: keptStyle == null ? const Opt<ProductSubStyle>.clear() : Opt(keptStyle),
        );
      },
    );

    // Drop the dimensions this category cannot use, rather than carrying a ring size onto a
    // necklace where nothing will ever show it again. Only worth a write if something is
    // actually stranded.
    final spec = current.productSpec;
    final strandsRing = !category.usesRingSize &&
        (spec?.ringSizeIn != null || spec?.ringSizeUs != null || spec?.ringSizeUk != null);
    final strandsDiameter = !category.usesInnerDiameter && spec?.innerDiaMm != null;
    final strandsLength = !category.usesLength && spec?.lengthMm != null;
    final strandsDrop = !category.usesDrop && spec?.dropMm != null;
    if (strandsRing || strandsDiameter || strandsLength || strandsDrop) {
      await editProductSpec(
        ringSizeIn: strandsRing ? const Opt<double>.clear() : null,
        ringSizeUs: strandsRing ? const Opt<double>.clear() : null,
        ringSizeUk: strandsRing ? const Opt<String>.clear() : null,
        innerDiaMm: strandsDiameter ? const Opt<double>.clear() : null,
        lengthMm: strandsLength ? const Opt<double>.clear() : null,
        dropMm: strandsDrop ? const Opt<double>.clear() : null,
      );
    }
    return null;
  }

  Future<String?> setSubStyle(ProductSubStyle style) async {
    _patch((d) => d.copyWith(job: d.job?.copyWith(subStyle: style)));
    _save('job.substyle', (id) => _jobs.patchJob(id, subStyle: Opt(style)));
    return null;
  }

  // ================================================================ step 4 — design spec

  void _seedProductSpec() {
    final current = _draft;
    final job = current?.job;
    if (current == null || job == null || current.productSpec != null) return;
    _patch((d) => d.copyWith(productSpec: ProductSpecEdit.blank(job.id)));
  }

  Future<String?> editProductSpec({
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
    Duration delay = SaveDelay.immediate,
  }) async {
    final job = _draft?.job;
    if (job == null) return null;
    final base = _draft?.productSpec ?? ProductSpecEdit.blank(job.id);

    _patch(
      (d) => d.copyWith(
        productSpec: base.edit(
          settingStyle: settingStyle,
          settingDetail: settingDetail,
          metalFinish: metalFinish,
          bandProfile: bandProfile,
          fit: fit,
          sideStones: sideStones,
          designIntent: designIntent,
          designIntentNote: designIntentNote,
          ringSizeIn: ringSizeIn,
          ringSizeUs: ringSizeUs,
          ringSizeUk: ringSizeUk,
          bandWidthMm: bandWidthMm,
          lengthMm: lengthMm,
          innerDiaMm: innerDiaMm,
          dropMm: dropMm,
          notes: notes,
        ),
      ),
    );

    _save(
      'spec.product',
      (id) async {
        await _specs.upsertProductSpec(
          id,
          settingStyle: settingStyle,
          settingDetail: settingDetail,
          metalFinish: metalFinish,
          bandProfile: bandProfile,
          fit: fit,
          sideStones: sideStones,
          designIntent: designIntent,
          designIntentNote: designIntentNote,
          ringSizeIn: ringSizeIn,
          ringSizeUs: ringSizeUs,
          ringSizeUk: ringSizeUk,
          bandWidthMm: bandWidthMm,
          lengthMm: lengthMm,
          innerDiaMm: innerDiaMm,
          dropMm: dropMm,
          notes: notes,
        );
      },
      delay: delay,
    );
    return null;
  }

  // ================================================================ step 5 — metal

  void _seedMetalSpec() {
    final current = _draft;
    final job = current?.job;
    if (current == null || job == null || current.metalSpec != null) return;
    _patch((d) => d.copyWith(metalSpec: MetalSpecEdit.blank(job.id)));
  }

  Future<String?> editMetalSpec({
    Opt<BaseMetal>? baseMetal,
    Opt<MetalPurity>? purity,
    Opt<MetalColor>? color,
    Opt<double>? targetWeightG,
    Opt<double>? weightTolG,
    bool? customerSupplied,
    Opt<String>? hallmark,
    Opt<String>? alloyNotes,
    Opt<bool>? gemstoneInset,
    Opt<Money>? targetBudgetMin,
    Opt<Money>? targetBudgetMax,
    Duration delay = SaveDelay.immediate,
  }) async {
    final job = _draft?.job;
    if (job == null) return null;
    final base = _draft?.metalSpec ?? MetalSpecEdit.blank(job.id);

    // The purity/base-metal dependency, mirrored locally so the screen agrees with the row.
    // The repository strands and clears exactly the same way (`_reconcilePurity`).
    var purityWrite = purity;
    final nextMetal = baseMetal == null ? base.baseMetal : baseMetal.value;
    final nextPurity = purity == null ? base.purity : purity.value;
    if (nextMetal != null && nextPurity != null && !nextMetal.purities.contains(nextPurity)) {
      if (purity != null) {
        return '${nextPurity.label} is not a ${nextMetal.label.toLowerCase()} purity. '
            'Choose one of ${[for (final p in nextMetal.purities) p.label].join(', ')}.';
      }
      purityWrite = const Opt<MetalPurity>.clear();
    }
    // Colour only means something for gold.
    final colorWrite = (nextMetal != null && !nextMetal.hasColor)
        ? const Opt<MetalColor>.clear()
        : color;

    _patch(
      (d) => d.copyWith(
        metalSpec: base.edit(
          baseMetal: baseMetal,
          purity: purityWrite,
          color: colorWrite,
          targetWeightG: targetWeightG,
          weightTolG: weightTolG,
          customerSupplied: customerSupplied,
          hallmark: hallmark,
          alloyNotes: alloyNotes,
          gemstoneInset: gemstoneInset,
          targetBudgetMinMinor: targetBudgetMin == null
              ? null
              : optOf(targetBudgetMin.value?.minor),
          targetBudgetMaxMinor: targetBudgetMax == null
              ? null
              : optOf(targetBudgetMax.value?.minor),
        ),
      ),
    );

    _save(
      'spec.metal',
      (id) async {
        await _specs.upsertMetalSpec(
          id,
          baseMetal: baseMetal,
          purity: purityWrite,
          color: colorWrite,
          targetWeightG: targetWeightG,
          weightTolG: weightTolG,
          customerSupplied:
              customerSupplied == null ? null : Opt<bool>(customerSupplied),
          hallmark: hallmark,
          alloyNotes: alloyNotes,
          gemstoneInset: gemstoneInset,
          targetBudgetMin: targetBudgetMin,
          targetBudgetMax: targetBudgetMax,
        );
      },
      delay: delay,
    );
    return null;
  }

  // ================================================================ step 6 — stones

  Future<String?> addStone({
    StoneRole role = StoneRole.center,
    StoneSourcing sourcing = StoneSourcing.needsSourcing,
    StoneType? stoneType,
    StoneOrigin? origin,
    StoneShape? shape,
  }) {
    final job = _draft?.job;
    if (job == null) return Future.value(null);
    return _act(() async {
      final stone = await _specs.addStone(
        jobId: job.id,
        role: role,
        sourcing: sourcing,
        stoneType: stoneType,
        origin: origin,
        shape: shape,
      );
      _patch((d) => d.copyWith(stones: [...d.stones, stone]));
    });
  }

  /// One edit, applied locally and written with the same arguments.
  ///
  /// `origin` is in here for the same reason it is in `Stone.openQuestions`: it survived in one
  /// of 46 mockups and every redesign after dropped it. Natural versus lab-grown changes
  /// valuation, disclosure and certification, so it is never inferred and never defaulted.
  Future<String?> editStone(
    String stoneId, {
    StoneRole? role,
    StoneSourcing? sourcing,
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
    bool? certRequired,
    Opt<CertLab>? certLab,
    Opt<String>? certNumber,
    Opt<String>? notes,
    Duration delay = SaveDelay.immediate,
  }) async {
    final current = _draft;
    if (current == null) return null;
    Stone? before;
    for (final s in current.stones) {
      if (s.id == stoneId) before = s;
    }
    if (before == null) return null;

    var next = before.edit(
      role: role,
      sourcing: sourcing,
      stoneType: stoneType,
      origin: origin,
      shape: shape,
      carat: carat,
      lengthMm: lengthMm,
      widthMm: widthMm,
      depthMm: depthMm,
      color: color,
      colorRange: colorRange,
      clarity: clarity,
      clarityRange: clarityRange,
      cut: cut,
      treatment: treatment,
      provenance: provenance,
      certRequired: certRequired,
      certLab: certLab,
      certNumber: certNumber,
      notes: notes,
    );

    // Species decides which grades exist. Changing a diamond into a ruby takes the 4Cs with it.
    final speciesChanged = stoneType != null && stoneType.value != before.stoneType;
    if (speciesChanged) next = next.reconciledForType();

    _patch(
      (d) => d.copyWith(
        stones: [
          for (final s in d.stones)
            if (s.id == stoneId) next else s,
        ],
      ),
    );

    _save(
      'stone.$stoneId',
      (_) async {
        await _specs.updateStone(
          stoneId,
          role: optOf(next.role),
          sourcing: optOf(next.sourcing),
          stoneType: optOf(next.stoneType),
          origin: optOf(next.origin),
          shape: optOf(next.shape),
          carat: optOf(next.carat),
          lengthMm: optOf(next.lengthMm),
          widthMm: optOf(next.widthMm),
          depthMm: optOf(next.depthMm),
          color: optOf(next.color),
          colorRange: optOf(next.colorRange),
          clarity: optOf(next.clarity),
          clarityRange: optOf(next.clarityRange),
          cut: optOf(next.cut),
          treatment: optOf(next.treatment),
          provenance: optOf(next.provenance),
          certRequired: optOf(next.certRequired),
          certLab: optOf(next.certLab),
          certNumber: optOf(next.certNumber),
          notes: optOf(next.notes),
        );
      },
      delay: delay,
    );
    return null;
  }

  Future<String?> removeStone(String stoneId) => _act(() async {
        await _specs.deleteStone(stoneId);
        _patch(
          (d) => d.copyWith(
            stones: [
              for (final s in d.stones)
                if (s.id != stoneId) s,
            ],
          ),
        );
      });

  /// Take custody of a client's own stone — completely, or not at all.
  ///
  /// The mockups had a `Reset Stone` job type and a "Verified & Logged in Inventory" chip and
  /// captured no declared value, no verifier, no timestamp, no receipt and no risk
  /// acknowledgement. The repository refuses a partial record; this passes the whole thing.
  Future<String?> recordCustody({
    required String stoneId,
    required Money declaredValue,
    required String receiptCode,
    required bool riskAck,
    DateTime? verifiedAt,
  }) =>
      _act(() async {
        final saved = await _specs.recordCustody(
          stoneId: stoneId,
          declaredValue: declaredValue,
          receiptCode: receiptCode,
          riskAck: riskAck,
          verifiedAt: verifiedAt,
        );
        _patch(
          (d) => d.copyWith(
            stones: [
              for (final s in d.stones)
                if (s.id == saved.id) saved else s,
            ],
          ),
        );
      });

  /// A photo of the client's stone, filed to the vault bucket rather than to customer-visible
  /// storage — it is valuation material.
  Future<String?> attachStonePhoto({required String stoneId, required File file}) {
    final job = _draft?.job;
    if (job == null) return Future.value(null);
    return _act(() async {
      final attachment = await _files.upload(
        UploadRequest.file(
          orgId: job.orgId,
          kind: AttachmentKind.stonePhoto,
          file: file,
          jobId: job.id,
        ),
      );
      final saved = await _specs.updateStone(
        stoneId,
        photoAttachment: Opt(attachment.id),
      );
      _patch(
        (d) => d.copyWith(
          attachments: [...d.attachments, attachment],
          stones: [
            for (final s in d.stones)
              if (s.id == saved.id) saved else s,
          ],
        ),
      );
    });
  }

  Future<String?> addMelee({
    StoneType stoneType = StoneType.diamond,
    StoneShape shape = StoneShape.roundBrilliant,
    StoneSourcing sourcing = StoneSourcing.needsSourcing,
    StoneOrigin? origin,
  }) {
    final job = _draft?.job;
    if (job == null) return Future.value(null);
    return _act(() async {
      final parcel = await _specs.addMelee(
        jobId: job.id,
        stoneType: stoneType,
        shape: shape,
        sourcing: sourcing,
        origin: origin,
      );
      _patch((d) => d.copyWith(melee: [...d.melee, parcel]));
    });
  }

  Future<String?> editMelee(
    String parcelId, {
    StoneSourcing? sourcing,
    StoneType? stoneType,
    Opt<StoneOrigin>? origin,
    StoneShape? shape,
    Opt<double>? sizeMinMm,
    Opt<double>? sizeMaxMm,
    Opt<double>? totalCtw,
    Opt<int>? pieceCount,
    Opt<String>? colorRange,
    Opt<String>? clarityRange,
    Opt<String>? notes,
    Duration delay = SaveDelay.immediate,
  }) async {
    final current = _draft;
    if (current == null) return null;
    MeleeParcel? before;
    for (final p in current.melee) {
      if (p.id == parcelId) before = p;
    }
    if (before == null) return null;

    final next = before.edit(
      sourcing: sourcing,
      stoneType: stoneType,
      origin: origin,
      shape: shape,
      sizeMinMm: sizeMinMm,
      sizeMaxMm: sizeMaxMm,
      totalCtw: totalCtw,
      pieceCount: pieceCount,
      colorRange: colorRange,
      clarityRange: clarityRange,
      notes: notes,
    );

    _patch(
      (d) => d.copyWith(
        melee: [
          for (final p in d.melee)
            if (p.id == parcelId) next else p,
        ],
      ),
    );

    _save(
      'melee.$parcelId',
      (_) async {
        await _specs.updateMelee(
          parcelId,
          sourcing: optOf(next.sourcing),
          stoneType: optOf(next.stoneType),
          origin: optOf(next.origin),
          shape: optOf(next.shape),
          sizeMinMm: optOf(next.sizeMinMm),
          sizeMaxMm: optOf(next.sizeMaxMm),
          totalCtw: optOf(next.totalCtw),
          pieceCount: optOf(next.pieceCount),
          colorRange: optOf(next.colorRange),
          clarityRange: optOf(next.clarityRange),
          notes: optOf(next.notes),
        );
      },
      delay: delay,
    );
    return null;
  }

  Future<String?> removeMelee(String parcelId) => _act(() async {
        await _specs.deleteMelee(parcelId);
        _patch(
          (d) => d.copyWith(
            melee: [
              for (final p in d.melee)
                if (p.id != parcelId) p,
            ],
          ),
        );
      });

  // ================================================================ step 7 — commercials

  /// One draft quote per job while intake runs. Created on entry so the cost lines have somewhere
  /// to land, and re-read after every line because Postgres recalculates the totals.
  Future<String?> ensureQuote() async {
    final current = _draft;
    final job = current?.job;
    if (current == null || job == null) return null;
    if (current.quote != null) return null;
    return _act(() async {
      final existing = await _quotes.latestQuote(job.id);
      final quote = existing ?? await _quotes.createQuote(jobId: job.id, currency: job.currency);
      _patch((d) => d.copyWith(quote: quote));
    });
  }

  Future<String?> setQuoteTerms({
    PricingBasis? basis,
    double? marginPct,
    Money? targetUnitPrice,
    Money? maxApproved,
    DateTime? validUntil,
  }) async {
    final quote = _draft?.quote;
    if (quote == null) return null;
    return _act(() async {
      final saved = await _quotes.updateQuoteTerms(
        quoteId: quote.id,
        basis: basis,
        marginPct: marginPct,
        targetUnitPrice: targetUnitPrice,
        maxApproved: maxApproved,
        validUntil: validUntil,
      );
      _patch((d) => d.copyWith(quote: saved));
    });
  }

  Future<String?> addCostLine({
    required CostCategory category,
    required String label,
    required Money unitAmount,
    String? detail,
    double qty = 1,
    Uom? unit,
    SuppliedBy suppliedBy = SuppliedBy.house,
    bool isClientOwned = false,
    Money? declaredValue,
  }) async {
    final quote = _draft?.quote;
    if (quote == null) return 'Open the pricing step again — the draft quote has not loaded yet.';
    return _act(() async {
      final saved = await _quotes.addCostLine(
        quoteId: quote.id,
        category: category,
        label: label,
        unitAmount: unitAmount,
        detail: detail,
        qty: qty,
        unit: unit,
        suppliedBy: suppliedBy,
        isClientOwned: isClientOwned,
        declaredValue: declaredValue,
      );
      _patch((d) => d.copyWith(quote: saved));
    });
  }

  Future<String?> updateCostLine({
    required String lineId,
    CostCategory? category,
    String? label,
    String? detail,
    double? qty,
    Uom? unit,
    Money? unitAmount,
    SuppliedBy? suppliedBy,
    bool? isClientOwned,
    // A client-owned line carries a declared value for insurance rather than a charge, and that
    // figure has to stay amendable — a valuation corrected after goods-in is normal.
    Money? declaredValue,
  }) async {
    final quote = _draft?.quote;
    if (quote == null) return null;
    return _act(() async {
      final saved = await _quotes.updateCostLine(
        quoteId: quote.id,
        lineId: lineId,
        category: category,
        label: label,
        detail: detail,
        qty: qty,
        unit: unit,
        unitAmount: unitAmount,
        suppliedBy: suppliedBy,
        isClientOwned: isClientOwned,
        declaredValue: declaredValue,
      );
      _patch((d) => d.copyWith(quote: saved));
    });
  }

  Future<String?> removeCostLine(String lineId) async {
    final quote = _draft?.quote;
    if (quote == null) return null;
    return _act(() async {
      final saved = await _quotes.removeCostLine(quoteId: quote.id, lineId: lineId);
      _patch((d) => d.copyWith(quote: saved));
    });
  }

  // ================================================================ step 8 — delivery

  void _seedDelivery() {
    final current = _draft;
    final job = current?.job;
    if (current == null || job == null || current.delivery != null) return;
    _patch(
      (d) => d.copyWith(
        delivery: DeliveryScheduleEdit.blank(job.id, priority: job.priority),
      ),
    );
  }

  /// Writes both `delivery_schedules` and the job header, because `jobs.requested_delivery` is
  /// what every list, board and due-date chip reads.
  Future<String?> editDelivery({
    Opt<DateTime>? requestedDate,
    bool? hardDeadline,
    bool? partialAllowed,
    Priority? priority,
    int? dispatchBufferD,
    int? certBufferD,
    Duration delay = SaveDelay.immediate,
  }) async {
    final current = _draft;
    final job = current?.job;
    if (current == null || job == null) return null;
    final base = current.delivery ?? DeliveryScheduleEdit.blank(job.id, priority: job.priority);

    // A rush job gets less slack in the plan, not a faster courier — the buffer the mockup
    // hardcoded at two days regardless.
    final nextPriority = priority ?? base.priority;
    final buffer = dispatchBufferD ??
        (priority == null
            ? base.dispatchBufferD
            : switch (nextPriority) {
                Priority.standard => 2,
                Priority.rush || Priority.critical => 1,
              });

    final next = base.edit(
      requestedDate: requestedDate,
      hardDeadline: hardDeadline,
      partialAllowed: partialAllowed,
      priority: nextPriority,
      dispatchBufferD: buffer,
      certBufferD: certBufferD,
    );

    _patch(
      (d) => d.copyWith(
        delivery: next,
        job: d.job?.copyWith(
          priority: nextPriority,
          hardDeadline: next.hardDeadline,
          partialAllowed: next.partialAllowed,
        ),
      ),
    );

    _save(
      'spec.delivery',
      (id) async {
        await _specs.upsertDelivery(
          id,
          requestedDate: optOf(next.requestedDate),
          hardDeadline: Opt(next.hardDeadline),
          partialAllowed: Opt(next.partialAllowed),
          priority: Opt(next.priority),
          dispatchBufferD: Opt(next.dispatchBufferD),
          certBufferD: Opt(next.certBufferD),
        );
        await _jobs.patchJob(
          id,
          priority: Opt(next.priority),
          requestedDelivery: optOf(next.requestedDate),
          hardDeadline: Opt(next.hardDeadline),
          partialAllowed: Opt(next.partialAllowed),
        );
      },
      delay: delay,
    );
    return null;
  }

  // ================================================================ step 9 — quality

  void _seedAcceptance() {
    final current = _draft;
    final job = current?.job;
    if (current == null || job == null || current.acceptance != null) return;
    _patch((d) => d.copyWith(acceptance: AcceptanceCriteriaEdit.blank(job.id)));
  }

  /// Choosing `CertLab.none` zeroes the certification buffer, and choosing a lab again restores
  /// it — the cross-screen dependency the mockups declared in a comment and never wired.
  /// `SpecRepository.upsertAcceptance` owns that write; this mirrors it locally.
  Future<String?> editAcceptance({
    bool? matchCad,
    bool? highPolish,
    bool? sizeWeightConform,
    bool? strictTolerance,
    Opt<double>? toleranceMm,
    bool? stonesSecure,
    bool? symmetry,
    CertLab? certLab,
    Opt<String>? certLabOther,
    QualityAuthority? authority,
    Opt<String>? customerNotes,
    Duration delay = SaveDelay.immediate,
  }) async {
    final current = _draft;
    final job = current?.job;
    if (current == null || job == null) return null;
    final base = current.acceptance ?? AcceptanceCriteriaEdit.blank(job.id);

    final next = base.edit(
      matchCad: matchCad,
      highPolish: highPolish,
      sizeWeightConform: sizeWeightConform,
      strictTolerance: strictTolerance,
      toleranceMm: toleranceMm,
      stonesSecure: stonesSecure,
      symmetry: symmetry,
      certLab: certLab,
      certLabOther: certLabOther,
      authority: authority,
      customerNotes: customerNotes,
    );

    final delivery = current.delivery;
    final certBuffer = certLab == null
        ? null
        : certLab.skipsStage
            ? 0
            : ((delivery?.certBufferD ?? 0) == 0 ? 3 : delivery!.certBufferD);

    _patch(
      (d) => d.copyWith(
        acceptance: next,
        delivery: certBuffer == null || d.delivery == null
            ? d.delivery
            : d.delivery!.edit(certBufferD: certBuffer),
      ),
    );

    _save(
      'spec.acceptance',
      (id) async {
        await _specs.upsertAcceptance(
          id,
          matchCad: Opt(next.matchCad),
          highPolish: Opt(next.highPolish),
          sizeWeightConform: Opt(next.sizeWeightConform),
          strictTolerance: Opt(next.strictTolerance),
          toleranceMm: optOf(next.toleranceMm),
          stonesSecure: Opt(next.stonesSecure),
          symmetry: Opt(next.symmetry),
          certLab: Opt(next.certLab),
          certLabOther: optOf(next.certLabOther),
          authority: Opt(next.authority),
          customerNotes: optOf(next.customerNotes),
        );
      },
      delay: delay,
    );
    return null;
  }

  // ================================================================ step 10 — review & commit

  /// Re-read what the server computed and write the D-009 requirement rows, so the review page
  /// shows figures nobody has to trust the client for.
  Future<String?> _prepareReview() async {
    final job = _draft?.job;
    if (job == null) return null;
    return _act(() async {
      await _specs.syncCoreRequirements(job.id);
      final quote = await _quotes.latestQuote(job.id);
      final gates = await _quotes.approvalGates(job.id);
      _patch((d) => d.copyWith(quote: quote ?? d.quote, gates: gates));
    });
  }

  /// Opens the three D-005 approval gates. `fn_commit_job` refuses to mint a code while any of
  /// them is unapproved, which is what stops a job reaching the shop floor unpriced.
  Future<String?> sendForApproval() {
    final job = _draft?.job;
    if (job == null) return Future.value(null);
    return _act(() async {
      final gates = await _quotes.ensureApprovalGates(job.id);
      _patch((d) => d.copyWith(gates: gates));
    });
  }

  Future<String?> decideGate({
    required ApprovalGate gate,
    required ApprovalGateState decision,
    String? note,
  }) =>
      _act(() async {
        final saved = await _quotes.decideGate(
          gateId: gate.id,
          state: decision,
          note: note,
        );
        _patch(
          (d) => d.copyWith(
            gates: [
              for (final g in d.gates)
                if (g.id == saved.id) saved else g,
            ],
          ),
        );
      });

  /// Mint the D-001 code, seed the 14-stage rail and write the audit event — all inside
  /// `fn_commit_job`, because a job with a code and no rail is unworkable and a rail with no code
  /// has nothing to print on the job bag.
  Future<String?> commit() async {
    await _queue.flush();
    final job = _draft?.job;
    if (job == null) return null;
    return _act(() async {
      await _jobs.commitJob(job.id);
      await _jobs.patchJob(job.id, wizardStep: const Opt(IntakeStep.total));
      final committed = await _jobs.getJob(job.id);
      final rail = await _jobs.getStageRail(job.id);
      _patch(
        (d) => d.copyWith(job: committed, rail: rail, step: IntakeStep.created),
      );
    });
  }

  // ================================================================ step 11 — created

  /// Hand the CAD stage to a designer. D-002: CAD is in-house, so this is an internal user and
  /// never a partner.
  Future<String?> assignCadDesigner(AppUser designer) {
    final job = _draft?.job;
    if (job == null) return Future.value(null);
    return _act(() async {
      await _jobs.assignStage(
        jobId: job.id,
        stage: LifecycleStage.cad,
        assignedTo: Opt(designer.id),
      );
      final rail = await _jobs.getStageRail(job.id);
      _patch((d) => d.copyWith(rail: rail, cadAssignee: designer));
    });
  }

  // ================================================================ housekeeping

  /// Push the whole local state again after a failed write. Cheaper than making the operator
  /// retype, and safe because every one of these is an upsert.
  Future<String?> retrySave() async {
    final current = _draft;
    final job = current?.job;
    if (current == null || job == null) return null;
    return _act(() async {
      await _jobs.patchJob(
        job.id,
        title: optOf(job.title),
        customerId: optOf(job.customerId),
        jobType: optOf(job.jobType),
        category: optOf(job.category),
        subStyle: optOf(job.subStyle),
        quantity: Opt(job.quantity),
        priority: Opt(job.priority),
        currency: Opt(job.currency),
        wizardStep: Opt(current.step.number),
      );
      final spec = current.productSpec;
      if (spec != null) {
        await _specs.upsertProductSpec(
          job.id,
          settingStyle: optOf(spec.settingStyle),
          settingDetail: optOf(spec.settingDetail),
          metalFinish: optOf(spec.metalFinish),
          bandProfile: optOf(spec.bandProfile),
          fit: optOf(spec.fit),
          sideStones: optOf(spec.sideStones),
          designIntent: optOf(spec.designIntent),
          designIntentNote: optOf(spec.designIntentNote),
          ringSizeIn: optOf(spec.ringSizeIn),
          ringSizeUs: optOf(spec.ringSizeUs),
          ringSizeUk: optOf(spec.ringSizeUk),
          bandWidthMm: optOf(spec.bandWidthMm),
          lengthMm: optOf(spec.lengthMm),
          innerDiaMm: optOf(spec.innerDiaMm),
          dropMm: optOf(spec.dropMm),
          notes: optOf(spec.notes),
        );
      }
      final metal = current.metalSpec;
      if (metal != null) {
        await _specs.upsertMetalSpec(
          job.id,
          baseMetal: optOf(metal.baseMetal),
          purity: optOf(metal.purity),
          color: optOf(metal.color),
          targetWeightG: optOf(metal.targetWeightG),
          weightTolG: optOf(metal.weightTolG),
          customerSupplied: Opt(metal.customerSupplied),
          hallmark: optOf(metal.hallmark),
          alloyNotes: optOf(metal.alloyNotes),
          gemstoneInset: optOf(metal.gemstoneInset),
          targetBudgetMin: optOf(metal.targetBudgetMin(job.currency)),
          targetBudgetMax: optOf(metal.targetBudgetMax(job.currency)),
        );
      }
      final delivery = current.delivery;
      if (delivery != null) {
        await _specs.upsertDelivery(
          job.id,
          requestedDate: optOf(delivery.requestedDate),
          hardDeadline: Opt(delivery.hardDeadline),
          partialAllowed: Opt(delivery.partialAllowed),
          priority: Opt(delivery.priority),
          dispatchBufferD: Opt(delivery.dispatchBufferD),
          certBufferD: Opt(delivery.certBufferD),
        );
      }
      final acceptance = current.acceptance;
      if (acceptance != null) {
        await _specs.upsertAcceptance(
          job.id,
          matchCad: Opt(acceptance.matchCad),
          highPolish: Opt(acceptance.highPolish),
          sizeWeightConform: Opt(acceptance.sizeWeightConform),
          strictTolerance: Opt(acceptance.strictTolerance),
          toleranceMm: optOf(acceptance.toleranceMm),
          stonesSecure: Opt(acceptance.stonesSecure),
          symmetry: Opt(acceptance.symmetry),
          certLab: Opt(acceptance.certLab),
          certLabOther: optOf(acceptance.certLabOther),
          authority: Opt(acceptance.authority),
          customerNotes: optOf(acceptance.customerNotes),
        );
      }
    });
  }

  /// Abandon the draft. Not a delete: D-005 keeps the trail, so the row is cancelled with a
  /// reason and the wizard opens a clean one.
  Future<String?> discardDraft() async {
    final job = _draft?.job;
    if (job == null) {
      startAnother();
      return null;
    }
    final failure = await _act(() async {
      await _jobs.cancelJob(job.id, reason: 'Draft abandoned during intake.');
    });
    if (failure != null) return failure;
    startAnother();
    return null;
  }

  /// Clear the wizard for the next job, keeping the workshop record already loaded.
  void startAnother() {
    final org = _draft?.org;
    state = AsyncData(IntakeDraft(org: org));
  }
}

/// `ref.intake(jobKey)` — the eleven step widgets reach the controller through this rather than
/// each spelling out the family key twice.
extension IntakeControllerRef on WidgetRef {
  IntakeController intake(String? jobKey) =>
      read(intakeControllerProvider(jobKey).notifier);
}
