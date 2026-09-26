/// The QC read layer: the checklist a job's own agreement generates, and everything one
/// inspection needs before it can be signed.
///
/// Why a gateway rather than more methods on `ProductionRepository`: that repository is
/// per-table and deliberately thin, while this surface is per-decision. An inspector standing in
/// front of `/qc/<job>` needs the job, its rail, the `acceptance_criteria` agreed at intake, the
/// `requirements` rows those criteria cite (D-009), the binding metal spec, the stones, the
/// locked CAD revision, every past attempt and the evidence files hanging off the current one.
/// A screen that renders four of those nine is showing a half-truth about an irreversible
/// authorisation.
///
/// **The checklist is the part the mockups got wrong.** `quality_control` shipped a *fixed five*
/// items with no relationship to what the shop had agreed to build, and the "inspection
/// evidence" dropzone behind them had no file input at all. Here the list is generated from
/// `acceptance_criteria` — the same row the customer signed at intake — every line carries the
/// binding figure it is measured against, and every line that has a requirement to cite carries
/// its code.
library;

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/repositories/spec_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'qc_gateway.g.dart';

// ================================================================= the generated checklist

/// One planned checklist line, before an inspection row exists to hold it.
///
/// [requirementCode] is a D-009 citation, not a label: it is resolved against the job's own
/// `requirements` rows so the inspector, the bench and the customer all point at the same spec
/// line. A plan with no code is not a defect — "Symmetry verified" answers to no single
/// requirement, and inventing one would make the citation meaningless everywhere else.
final class QcChecklistPlan {
  const QcChecklistPlan({
    required this.label,
    this.helper,
    this.requirementCode,
    this.critical = false,
  });

  /// 'Metal weight and size verified'.
  final String label;

  /// 'Target: 4.8 g Pt 950. Allowable variance: ± 0.2 g.' — the mockup's own phrasing, which
  /// already read like a requirement citation. That instinct is what D-009 formalises.
  final String? helper;

  /// 'REQ-MAT-01', or null where no requirement governs the line.
  final String? requirementCode;

  /// A line QC will fail the piece over rather than note. Renders in the house gold.
  final bool critical;
}

/// Turns the agreement into the inspection.
///
/// The labels come from [AcceptanceCriteria.checklistLabels] and are **not** restated here —
/// that getter is the single source for what the list contains, and this class only adds the
/// helper text and the citation for each line. The assertion at the end is what keeps the two
/// from drifting: if someone adds a criterion to the model and forgets this file, a debug build
/// fails immediately instead of shipping an inspection that is missing a check.
abstract final class QcChecklistBuilder {
  /// The checklist for one job, in the order an inspector works it.
  static List<QcChecklistPlan> plan({
    required AcceptanceCriteria acceptance,
    MetalSpec? metal,
    ProductSpec? product,
    ProductCategory? category,
    List<Stone> stones = const <Stone>[],
    List<MeleeParcel> melee = const <MeleeParcel>[],
    CadRevision? cad,
  }) {
    final plans = <QcChecklistPlan>[
      if (acceptance.matchCad)
        QcChecklistPlan(
          label: 'Matches approved CAD',
          helper: _cadHelper(cad),
          critical: true,
        ),
      if (acceptance.sizeWeightConform)
        QcChecklistPlan(
          label: 'Metal weight and size verified',
          helper: _weightHelper(metal, product, category),
          // The binding weight is a property of the metal specification, which REQ-MAT-01 is the
          // citation for. It is also the one spec `order_details` rendered in gold.
          requirementCode: _reqBaseMetal,
          critical: true,
        ),
      if (acceptance.stonesSecure)
        QcChecklistPlan(
          label: 'All stones secure',
          helper: _stoneHelper(stones, melee),
          requirementCode: _reqGemstoneInset,
          critical: true,
        ),
      if (acceptance.symmetry)
        QcChecklistPlan(
          label: 'Symmetry verified',
          helper: _symmetryHelper(acceptance),
        ),
      if (acceptance.highPolish)
        QcChecklistPlan(
          label: 'Finish and polish to standard',
          helper: _finishHelper(product),
        ),
      if (!acceptance.skipsCertification)
        QcChecklistPlan(
          label: 'Certificate received and matches piece',
          helper: 'Lab: ${acceptance.certLabLabel}. The number on the report has to match the '
              'piece in your hand, not just the job card.',
          critical: true,
        ),
      // D-002: hallmarking survives from the rejected mobile tracker's "Final QC & Hallmarking"
      // because it is a real Indian-market requirement, not a nice-to-have.
      QcChecklistPlan(
        label: 'Hallmark applied',
        helper: _hallmarkHelper(metal),
        requirementCode: _reqAlloyPurity,
        critical: true,
      ),
    ];

    assert(
      const ListEquality<String>().equals(
        [for (final line in plans) line.label],
        acceptance.checklistLabels,
      ),
      'QcChecklistBuilder has drifted from AcceptanceCriteria.checklistLabels. The model owns '
      'what the list contains; this builder only adds helpers and citations.',
    );
    return plans;
  }

  /// The three of D-009's five codes a QC line can honestly cite.
  static const _reqBaseMetal = 'REQ-MAT-01';
  static const _reqAlloyPurity = 'REQ-PUR-02';
  static const _reqGemstoneInset = 'REQ-GEM-03';

  static String _cadHelper(CadRevision? cad) {
    if (cad == null) {
      return 'No CAD version is locked on this job. Measure against the signed spec sheet and '
          'say so in the inspection notes.';
    }
    final locked = cad.isLocked
        ? 'It is locked, so what you are holding is what the customer approved.'
        : 'It is NOT locked — check that no newer version superseded it before you sign.';
    return 'Compare against CAD ${cad.version}. $locked';
  }

  static String _weightHelper(
    MetalSpec? metal,
    ProductSpec? product,
    ProductCategory? category,
  ) {
    final parts = <String>[];
    final target = metal?.targetWeightG;
    if (metal != null && target != null) {
      parts.add('Target: ${gramLabel(target)} ${metal.alloyLabel}.');
      final tol = metal.weightTolG;
      parts.add(
        tol == null
            ? 'No variance was agreed — weigh it, record the actual, and flag anything that '
                'surprises you.'
            : 'Allowable variance: ${toleranceLabel(tol)}.',
      );
    } else {
      parts.add('No target weight was agreed at intake. Weigh the piece and record the actual '
          'on the measurement sheet.');
    }
    if (product != null && category != null) {
      final size = product.dimensionLabel(category);
      if (size != '—') parts.add('Size: $size.');
    }
    return parts.join(' ');
  }

  static String _stoneHelper(List<Stone> stones, List<MeleeParcel> melee) {
    if (stones.isEmpty && melee.isEmpty) {
      return 'No stones are recorded on this job card. If the piece is set, the job card is '
          'wrong and the setter has to be asked before you pass this line.';
    }
    final counted = <String>[
      if (stones.isNotEmpty) '${stones.length} set stone${stones.length == 1 ? '' : 's'}',
      if (melee.isNotEmpty) '${melee.length} melee parcel${melee.length == 1 ? '' : 's'}',
    ].join(' and ');

    // stones.origin is never dropped from a surface. It survived in exactly one of the 46
    // mockups, and natural versus lab-grown changes valuation and disclosure.
    final named = [
      for (final stone in stones.sorted((a, b) => a.position.compareTo(b.position)).take(3))
        '${stone.displayTitle} ${stone.caratText}'
            '${stone.origin == null ? '' : ' (${stone.origin!.label})'}',
    ].join(', ');

    return named.isEmpty ? '$counted on the job card.' : '$counted on the job card: $named.';
  }

  static String _symmetryHelper(AcceptanceCriteria acceptance) {
    final tol = 'Dimensional tolerance ± ${mmLabel(acceptance.effectiveToleranceMm)}.';
    return acceptance.strictTolerance
        ? '$tol Strict tolerance was opted into at intake, so this is the agreed figure and not '
            'the shop default.'
        : '$tol The shop default — strict tolerance was not asked for.';
  }

  static String _finishHelper(ProductSpec? product) {
    final finish = product?.metalFinish;
    if (finish == null) {
      return 'No finish was specified at intake. Inspect to shop standard for a polished piece.';
    }
    final band = product?.bandProfile;
    return band == null
        ? 'Agreed finish: ${finish.label}.'
        : 'Agreed finish: ${finish.label} on a ${band.label.toLowerCase()} profile.';
  }

  static String _hallmarkHelper(MetalSpec? metal) {
    final mark = metal?.hallmark?.trim();
    if (mark != null && mark.isNotEmpty) return 'Hallmark to stamp: $mark.';
    final purity = metal?.purity?.label;
    return purity == null
        ? 'Stamp the agreed purity and the maker\'s mark. No hallmark string was recorded at '
            'intake — confirm it before stamping.'
        : 'Stamp $purity and the maker\'s mark.';
  }
}

// ================================================================= the bundle

/// One inspection, fully loaded.
final class QcBundle {
  const QcBundle({
    required this.job,
    required this.rail,
    required this.acceptance,
    required this.requirementsByCode,
    required this.metal,
    required this.product,
    required this.stones,
    required this.melee,
    required this.cad,
    required this.inspections,
    required this.evidence,
    required this.evidenceUrls,
    required this.measurements,
    required this.people,
  });

  final Job job;

  /// D-005: where the job actually is. An authorisation closes a stage, so the rail — not
  /// `jobs.current_stage` — decides which one.
  final StageRail rail;

  /// What the piece is measured against, agreed at intake. Null means nobody ever agreed
  /// anything, which is a gap the screen has to say out loud rather than paper over with a
  /// default five-item list.
  final AcceptanceCriteria? acceptance;

  /// D-009 citations, keyed by code.
  final Map<String, Requirement> requirementsByCode;

  final MetalSpec? metal;
  final ProductSpec? product;
  final List<Stone> stones;
  final List<MeleeParcel> melee;

  /// The revision the piece is measured against. "Matches approved CAD" is meaningless without
  /// naming which CAD.
  final CadRevision? cad;

  /// Every attempt, newest first. D-006: a reinspection after rework is its own attempt rather
  /// than an overwrite of the failure.
  final List<QcInspection> inspections;

  /// Evidence rows keyed by attachment id, and short-lived signed URLs for the images among
  /// them. Signed, never public — QC evidence lives in the `vault` bucket.
  final Map<String, Attachment> evidence;
  final Map<String, String> evidenceUrls;

  /// What the bench actually weighed, newest first. No mockup captured a single production
  /// measurement, which is why `measurement_entry.dart` exists.
  final List<StageMeasurement> measurements;

  /// Inspectors and the people who ticked lines, keyed by id. D-008: every name on screen came
  /// off a row, never a literal.
  final Map<String, AppUser> people;

  AppUser? person(String? id) => id == null ? null : people[id];

  String nameFor(String? id, {String fallback = 'Unrecorded'}) =>
      person(id)?.fullName ?? fallback;

  /// The attempt on the table right now.
  QcInspection? get current => inspections.firstOrNull;

  /// Everything before it, for the history block.
  List<QcInspection> get earlierAttempts =>
      inspections.length < 2 ? const <QcInspection>[] : inspections.sublist(1);

  JobStage? get qcStage => rail.stageFor(LifecycleStage.qc);

  /// The rail row an authorisation closes, or null when the job is not standing at QC. Anything
  /// else — a job still at polishing, a rail not yet seeded — must not be advanced by a QC
  /// signature, and saying so beats guessing.
  JobStage? get stageToClose {
    final active = rail.activeStage;
    return active != null && active.stage == LifecycleStage.qc ? active : null;
  }

  /// Why an authorisation will not move the job, for the confirm dialog to say out loud.
  String? get advanceNote {
    if (stageToClose != null) return null;
    final active = rail.activeStage;
    if (active == null) {
      return 'This job has no active stage, so authorising records the sign-off without moving '
          'anything.';
    }
    return 'The job is at ${active.stage.label}, not QC. The authorisation is recorded and the '
        'rail stays where it is.';
  }

  /// The checklist this job generates. Empty when nothing was agreed at intake.
  List<QcChecklistPlan> get plan {
    final agreed = acceptance;
    if (agreed == null) return const <QcChecklistPlan>[];
    return QcChecklistBuilder.plan(
      acceptance: agreed,
      metal: metal,
      product: product,
      category: job.category,
      stones: stones,
      melee: melee,
      cad: cad,
    );
  }

  /// The seed rows for a new inspection, with every citation resolved to a `requirements.id`.
  List<QcSeedItem> get seed => [
        for (final line in plan)
          QcSeedItem(
            line.label,
            helper: line.helper,
            requirementId: requirementIdFor(line.requirementCode),
          ),
      ];

  String? requirementIdFor(String? code) =>
      code == null ? null : requirementsByCode[code]?.id;

  Requirement? requirementFor(String? code) =>
      code == null ? null : requirementsByCode[code];

  /// The citation on a stored checklist item, found by id rather than by code — the inspection
  /// is the record of what was cited when it was opened, and a later spec edit must not silently
  /// re-point it.
  Requirement? requirementOf(QcChecklistItem item) {
    final id = item.requirementId;
    if (id == null) return null;
    return requirementsByCode.values.firstWhereOrNull((r) => r.id == id);
  }

  /// The plan line behind a stored item, for the helper and the critical flag.
  QcChecklistPlan? planFor(QcChecklistItem item) =>
      plan.firstWhereOrNull((line) => line.label == item.label);

  Attachment? evidenceOf(QcChecklistItem item) =>
      item.evidenceId == null ? null : evidence[item.evidenceId];

  String? evidenceUrlOf(QcChecklistItem item) =>
      item.evidenceId == null ? null : evidenceUrls[item.evidenceId];

  bool get hasAgreement => acceptance != null;

  /// A reinspection is owed: the last attempt failed and the piece has been back to the bench.
  bool get awaitingReinspection => current?.isFailed ?? false;

  int get nextAttempt => (current?.attempt ?? 0) + 1;

  /// Whether an inspection can be opened right now. An open, unfinished attempt is never
  /// replaced — that would erase a partly-worked checklist.
  bool get canOpenInspection =>
      plan.isNotEmpty && (current == null || current!.isFailed);

  /// Why "Open the inspection" is shut, phrased for the inspector.
  String? get openBlockedReason {
    if (acceptance == null) {
      return 'Nothing was agreed for this job at intake, so there is no checklist to generate. '
          'Fill in the quality step on the job order first.';
    }
    if (plan.isEmpty) {
      return 'Every acceptance criterion on this job was turned off, so the checklist is empty. '
          'An inspection with no items can never be authorised.';
    }
    final open = current;
    if (open != null && !open.isFailed) {
      return 'Attempt ${open.attempt} is already open at ${open.progressLabel}. Finish or fail '
          'it before starting another.';
    }
    return null;
  }

  /// Selecting `customer` as the authority inserts a portal approval gate before sign-off. The
  /// mockups offered the option and had no such transition or screen, so the screen states it.
  bool get needsCustomerGate => acceptance?.needsCustomerGate ?? false;

  /// The binding weight the bench is held to, copied onto a measurement at the moment it is
  /// taken so a later spec edit cannot retroactively fail a passed measurement.
  double? get targetWeightG => metal?.targetWeightG;

  double? get toleranceG => metal?.weightTolG;

  /// The newest measurement taken anywhere on the job, which is the figure QC reads.
  StageMeasurement? get latestMeasurement => measurements.firstOrNull;

  /// A measurement exists and is outside the agreed tolerance. QC does not block on this —
  /// the inspector decides — but a screen that stays quiet about it is not doing its job.
  bool get measurementOutOfTolerance {
    final latest = latestMeasurement;
    return latest != null && !latest.isWithinTolerance;
  }

  /// No weight has ever been recorded against a job whose spec binds one.
  bool get measurementMissing => targetWeightG != null && measurements.isEmpty;
}

// ================================================================= measurement context

/// What `measurement_entry.dart` opens with.
///
/// Separate from [QcBundle] because a measurement is taken at the bench, at casting and at
/// polishing — not only at QC — and loading nine reads to weigh a ring would be absurd.
final class MeasurementContext {
  const MeasurementContext({
    required this.job,
    required this.rail,
    required this.metal,
    required this.measurements,
  });

  final Job job;
  final StageRail rail;

  /// The binding spec. `order_details` rendered "Target Weight 4.2g ±0.1g" in gold — the only
  /// spec in the corpus given that treatment — and then made it read-only with no way to record
  /// what was actually made.
  final MetalSpec? metal;

  /// Every measurement on the job, newest first.
  final List<StageMeasurement> measurements;

  double? get targetG => metal?.targetWeightG;
  double? get toleranceG => metal?.weightTolG;

  /// '8.5 g ± 0.5 g', or an em dash when nothing binds the bench.
  String get specLabel => metal?.weightLabel ?? '—';

  bool get hasSpec => targetG != null;

  /// The stage a measurement defaults to: wherever the job is standing now.
  LifecycleStage get defaultStage =>
      rail.activeLifecycle ?? job.currentStage ?? LifecycleStage.qc;

  /// The stages it makes sense to weigh at. Weighing at `inquiry` or `dispatch` is not a
  /// production measurement, and offering all fourteen would make the picker useless.
  static const measurableStages = <LifecycleStage>[
    LifecycleStage.wax,
    LifecycleStage.casting,
    LifecycleStage.assembly,
    LifecycleStage.setting,
    LifecycleStage.polishing,
    LifecycleStage.qc,
  ];

  List<StageMeasurement> forStage(LifecycleStage stage) =>
      [for (final row in measurements) if (row.stage == stage) row];

  StageMeasurement? latestFor(LifecycleStage stage) => forStage(stage).firstOrNull;

  /// Total loss recorded across the job — filings, polishing loss and casting sprues. Real,
  /// measurable, and never modelled by the mockups even though their own dashboard raised stock
  /// mismatch alerts.
  double get totalScrapG {
    var total = 0.0;
    for (final row in measurements) {
      total += row.scrapG ?? 0.0;
    }
    return total;
  }

  bool get hasScrap => totalScrapG > 0;
}

// ================================================================= gateway

final class QcGateway {
  const QcGateway(
    this._client,
    this._identity,
    this._store,
    this._jobs,
    this._specs,
    this._production,
  );

  final SupabaseClient _client;
  final RepoIdentity _identity;
  final AttachmentStore _store;
  final JobRepository _jobs;
  final SpecRepository _specs;
  final ProductionRepository _production;

  /// The `app_users` columns a name needs. `user_roles` is deliberately not joined: this is for
  /// rendering who did what, and a role badge is not part of that.
  static const _peopleSelect = 'id, org_id, principal, full_name, title, initials, email, '
      'phone, avatar_path, is_active, created_at';

  /// Everything `/qc/<jobId>` renders.
  ///
  /// The reads are sequential on purpose. Running them together with `.wait` would replace a
  /// [DhFailure] — which carries the server's own operator-facing sentence — with a
  /// `ParallelWaitError`, and those sentences are the product.
  Future<QcBundle> bundle(String jobId) async {
    final snapshot = await _jobs.getSnapshot(jobId);
    final acceptance = await _specs.getAcceptance(jobId);
    final requirements = await _specs.listRequirements(jobId);
    final metal = await _specs.getMetalSpec(jobId);
    final product = await _specs.getProductSpec(jobId);
    final stones = await _specs.listStones(jobId);
    final melee = await _specs.listMelee(jobId);
    final cad = await _production.currentCadRevision(jobId);
    final inspections = await _production.qcInspections(jobId);
    final measurements = await _production.measurements(jobId);

    final evidenceIds = <String?>[
      for (final inspection in inspections)
        for (final item in inspection.items) item.evidenceId,
    ];
    final evidence = await _filesFor(evidenceIds);
    final images = [for (final file in evidence.values) if (file.isImage) file];
    final urls = images.isEmpty
        ? const <String, String>{}
        : await _store.signedUrls(images);

    final people = await _peopleFor(<String?>[
      for (final inspection in inspections) ...[
        inspection.inspectorId,
        for (final item in inspection.items) item.checkedBy,
      ],
      for (final row in measurements) row.measuredBy,
      cad?.designerId,
    ]);

    return QcBundle(
      job: snapshot.job,
      rail: snapshot.rail,
      acceptance: acceptance,
      requirementsByCode: {for (final row in requirements) row.code: row},
      metal: metal,
      product: product,
      stones: stones,
      melee: melee,
      cad: cad,
      inspections: inspections,
      evidence: evidence,
      evidenceUrls: urls,
      measurements: measurements,
      people: people,
    );
  }

  Future<MeasurementContext> measurementContext(String jobId) async {
    final snapshot = await _jobs.getSnapshot(jobId);
    final metal = await _specs.getMetalSpec(jobId);
    final measurements = await _production.measurements(jobId);
    return MeasurementContext(
      job: snapshot.job,
      rail: snapshot.rail,
      metal: metal,
      measurements: measurements,
    );
  }

  /// Put a reworked piece back into production so a reinspection can be opened against it.
  ///
  /// `JobRepository.patchJob` deliberately excludes `status`, and of the three status methods it
  /// does expose only `releaseHold` has an inverse — there is none for `rework`. A job left at
  /// `rework` drops out of `v_stage_counters`, which is correct while the bench holds the piece
  /// and wrong the moment QC takes it back. So the column is written here, next to the act that
  /// justifies it, and D-005 is honoured: the transition writes its own `activity_events` row,
  /// because a status that changed with nothing on the record is exactly what an append-only
  /// audit log exists to prevent.
  Future<Job> reopenForInspection(String jobId, {required int attempt}) async {
    final job = await _jobs.getJob(jobId);
    if (job.status != JobStatus.rework) return job;

    final reopened = await guard(
      () => _client
          .from('jobs')
          .update(<String, Object?>{'status': JobStatus.inProduction.wire})
          .eq('id', jobId)
          .select()
          .single(),
    );

    await guard(
      () => _client.from('activity_events').insert(<String, Object?>{
        'job_id': jobId,
        'kind': ActivityKind.system.wire,
        'actor_id': _identity.userId,
        'actor_label': _identity.displayName,
        'stage': LifecycleStage.qc.wire,
        'summary': 'Back from rework for reinspection',
        'detail': 'Attempt $attempt opened. The failed attempt stays on the record.',
      }),
    );

    return Job.fromJson(reopened);
  }

  Future<Map<String, Attachment>> _filesFor(Iterable<String?> ids) async {
    final wanted = <String>{for (final id in ids) if (id != null) id};
    if (wanted.isEmpty) return const <String, Attachment>{};
    final rows = await guard(
      () => _client.from('attachments').select().inFilter('id', wanted.toList()),
    );
    final out = <String, Attachment>{};
    for (final row in rows) {
      final file = Attachment.fromJson(row);
      out[file.id] = file;
    }
    return out;
  }

  Future<Map<String, AppUser>> _peopleFor(Iterable<String?> ids) async {
    final wanted = <String>{for (final id in ids) if (id != null) id};
    if (wanted.isEmpty) return const <String, AppUser>{};
    final rows = await guard(
      () => _client.from('app_users').select(_peopleSelect).inFilter('id', wanted.toList()),
    );
    final out = <String, AppUser>{};
    for (final row in rows) {
      final user = AppUser.fromJson(row);
      out[user.id] = user;
    }
    return out;
  }
}

// ================================================================= providers

@Riverpod(keepAlive: true)
QcGateway qcGateway(Ref ref) => QcGateway(
      ref.watch(supabaseProvider),
      ref.watch(repoIdentityProvider),
      ref.watch(attachmentStoreProvider),
      ref.watch(jobRepositoryProvider),
      ref.watch(specRepositoryProvider),
      ref.watch(productionRepositoryProvider),
    );

/// One inspection, re-read on demand.
///
/// Deliberately not live. An authorisation is irreversible, and a screen that reshuffles its
/// checklist under the inspector's thumb mid-decision is worse than one that needs a pull to
/// refresh. Every QC action invalidates this when it lands.
@riverpod
Future<QcBundle> qcBundle(Ref ref, String jobId) =>
    ref.watch(qcGatewayProvider).bundle(jobId);

@riverpod
Future<MeasurementContext> measurementContext(Ref ref, String jobId) =>
    ref.watch(qcGatewayProvider).measurementContext(jobId);
