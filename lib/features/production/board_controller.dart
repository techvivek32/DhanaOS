/// The production board's data layer: a live eight-column read, the rail rule a drag has to
/// obey, and the optimistic move a drop commits.
///
/// The mockup's board drew **three** of the eight columns — Assembly, Setting, QC and
/// Certification were missing outright — and its own source admitted the column counts never
/// updated. Both faults are structural rather than cosmetic, so they are fixed here rather than
/// in the widget: the columns are [LifecycleStage.operational] (D-002), and every count is
/// recomputed from the cards actually in the column.
///
/// A drag is not a free-form move. Stage history is append-only (D-005) and `fn_complete_stage`
/// closes the active stage and opens the next *pending* one on that job's own rail — it cannot
/// jump two stages and it cannot go back. So the board offers exactly one legal drop per card
/// and explains every other drop instead of swallowing it.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/data/repositories/dashboard_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/features/auth/permissions.dart';

part 'board_controller.g.dart';

// ================================================================= the rail rule

/// What completing one stage does, read off the 14-stage rail (D-002).
@immutable
final class StageTransition {
  const StageTransition({required this.from, required this.to});

  /// The transition that leaves [from], or null at `delivered`, which has nothing after it.
  ///
  /// This is the *nominal* successor. The authority is `fn_complete_stage`, which opens the next
  /// row with `state = 'pending'` and so may skip a stage this job never needed — certification
  /// on an uncertified piece, for one. That is why [BoardMoves.complete] replaces its optimistic
  /// position with a confirmed read instead of trusting this value.
  static StageTransition? after(LifecycleStage from) {
    final next = from.index + 1;
    if (next >= LifecycleStage.values.length) return null;
    return StageTransition(from: from, to: LifecycleStage.values[next]);
  }

  final LifecycleStage from;
  final LifecycleStage to;

  /// True when the successor is one of the eight columns the board draws.
  ///
  /// Three of the eight complete into something the board does not show: `approval` into
  /// `pricing`, `setting` into `polishing`, `cert` into `dispatch`. Those jobs leave the board
  /// until they re-enter at `wax`, `qc` or not at all — which is why they are completed from the
  /// card menu rather than by dropping them somewhere they do not belong.
  bool get staysOnBoard => LifecycleStage.operational.contains(to);

  /// Who may press it.
  ///
  /// Completing the QC stage *is* the authorisation — `fn_complete_stage` refuses it while any
  /// checklist item is unticked (D-011 rule 3) — so it takes the QC capability rather than the
  /// general edit one.
  Capability get capability =>
      from == LifecycleStage.qc ? Capability.authorizeQc : Capability.editJob;

  /// A sentence for the confirm dialog, naming where the job actually goes.
  String get destinationSentence => staysOnBoard
      ? 'It moves to the ${to.label} column.'
      : 'It moves to ${to.label}, which is not a board column — the job leaves the board until '
          'it reaches its next operational stage.';

  /// The rule the server will check, in the words it will use. Null for stages with no gate.
  ///
  /// D-011 rules 1 and 3 are enforced in Postgres and refuse with operator-facing text. Saying
  /// so *before* the press is the difference between a rule and a surprise.
  String? get serverGate => switch (from) {
        LifecycleStage.casting =>
          'A casting photo has to be on file first — the server refuses this without one.',
        LifecycleStage.qc =>
          'Every checklist item has to be ticked first — a partial checklist is refused.',
        _ => null,
      };
}

/// Why a card cannot be dropped on [onto], or null when that drop is the one real transition.
///
/// A sentence rather than a bool, because a rejected drag that explains nothing is exactly what
/// the mockup's dead controls already were.
String? dropRefusal({required LifecycleStage from, required LifecycleStage onto}) {
  if (onto == from) return null;
  final move = StageTransition.after(from);
  if (move == null) {
    return '${from.label} is the last stage on the rail. Nothing follows it.';
  }
  if (!move.staysOnBoard) {
    return '${from.label} completes into ${move.to.label}, which is not a board column. Use the '
        'card menu to complete it.';
  }
  if (onto != move.to) {
    return 'A job advances one stage at a time and never backwards — stage history is '
        'append-only. ${from.label} completes into ${move.to.label}.';
  }
  return null;
}

// ================================================================= optimistic state

/// A move the operator has made and the server has not confirmed yet.
@immutable
final class PendingMove {
  const PendingMove({required this.jobId, required this.from, required this.to});

  final String jobId;
  final LifecycleStage from;
  final LifecycleStage to;

  bool get leavesBoard => !LifecycleStage.operational.contains(to);
}

/// The board as drawn: the server's eight columns with any in-flight move already applied.
///
/// [ProductionBoard] is what the server said; this is what the operator is looking at, and the
/// two are allowed to differ for exactly as long as a commit is in flight.
final class BoardView {
  const BoardView._(this._byStage, this._moves);

  factory BoardView(ProductionBoard board, Map<String, PendingMove> moves) {
    final grouped = <LifecycleStage, List<BoardCard>>{
      for (final stage in LifecycleStage.operational) stage: <BoardCard>[],
    };
    for (final stage in LifecycleStage.operational) {
      for (final card in board.cardsIn(stage)) {
        final move = moves[card.jobId];
        // A move whose `from` no longer matches has already been overtaken by real data.
        if (move == null || move.from != card.columnStage) {
          grouped[stage]!.add(card);
          continue;
        }
        // Off the board: drop it, which is what the confirmed read will show anyway.
        if (move.leavesBoard) continue;
        grouped[move.to]!.add(_relocated(card, move.to));
      }
    }
    return BoardView._(grouped, moves);
  }

  /// The card as it will look in its new column. The stage clock restarts, so carrying the old
  /// dwell figure over would make a card that moved seconds ago read as three days stuck.
  static BoardCard _relocated(BoardCard card, LifecycleStage to) => BoardCard(
        jobId: card.jobId,
        columnStage: to,
        displayCode: card.displayCode,
        priority: card.priority,
        title: card.title,
        customerName: card.customerName,
        requestedDelivery: card.requestedDelivery,
        enteredAt: DateTime.now().toUtc(),
        daysInStage: 0,
        assigneeName: card.assigneeName,
        partnerName: card.partnerName,
      );

  final Map<LifecycleStage, List<BoardCard>> _byStage;
  final Map<String, PendingMove> _moves;

  /// Always all eight, in rail order. An empty column is information — the mockup drew three and
  /// left the operator to guess what had happened to the rest.
  List<LifecycleStage> get columns => LifecycleStage.operational;

  List<BoardCard> cardsIn(LifecycleStage stage) => _byStage[stage] ?? const <BoardCard>[];

  /// Recomputed from the cards, never carried as a number. The mockup's counts were literals its
  /// own source admitted never moved.
  int countIn(LifecycleStage stage) => cardsIn(stage).length;

  int get total {
    var count = 0;
    for (final stage in columns) {
      count += countIn(stage);
    }
    return count;
  }

  bool get isEmpty => total == 0;

  /// How many jobs on the board are already past their delivery date.
  int get overdueCount {
    var count = 0;
    for (final stage in columns) {
      for (final card in cardsIn(stage)) {
        if (card.overdue) count++;
      }
    }
    return count;
  }

  PendingMove? moveFor(String jobId) => _moves[jobId];

  bool isMoving(String jobId) => _moves.containsKey(jobId);

  bool get hasPendingMoves => _moves.isNotEmpty;
}

// ================================================================= providers

/// All eight columns, re-read whenever a rail row or a job changes.
///
/// PostgREST cannot stream a view and `v_production_board` is a view, so the channel is used as a
/// change signal and the view is re-read — which is what `liveQuery` exists for. `jobs` is
/// watched as well as `job_stages` because a priority change or a new delivery date changes a
/// card without touching the rail.
@riverpod
Stream<Live<ProductionBoard>> liveProductionBoard(Ref ref) {
  final repo = ref.watch(dashboardRepositoryProvider);
  return liveQuery<ProductionBoard>(
    client: ref.watch(supabaseProvider),
    channelName: 'production-board',
    tables: const [LiveTable(table: 'job_stages'), LiveTable(table: 'jobs')],
    read: repo.productionBoard,
  );
}

/// Which column the phone layout shows, and where a dashboard counter deep-links to.
///
/// Kept alive so tapping "At Casting · 12" on the dashboard and arriving at the board lands on
/// Casting rather than on whatever column happened to be open last.
@Riverpod(keepAlive: true)
class FocusedColumn extends _$FocusedColumn {
  @override
  LifecycleStage build() => LifecycleStage.cad;

  /// Ignores a stage that is not one of the eight, so a caller cannot focus a column that does
  /// not exist.
  void select(LifecycleStage stage) {
    if (LifecycleStage.operational.contains(stage)) state = stage;
  }
}

/// The moves in flight, keyed by job.
///
/// Kept alive so a commit survives the operator flicking to another tab while the round trip is
/// still open — losing the override mid-flight would snap the card back into a column it has
/// already left.
@Riverpod(keepAlive: true)
class BoardMoves extends _$BoardMoves {
  @override
  Map<String, PendingMove> build() => const <String, PendingMove>{};

  bool isMoving(String jobId) => state.containsKey(jobId);

  /// Complete [card]'s stage.
  ///
  /// The card moves locally first so the board answers the gesture in the same frame, and goes
  /// back if the server refuses — which it will for a casting stage with no photo (D-011 rule 1)
  /// or a QC stage with an unticked item (rule 3). The refusal reaches the caller as a
  /// [DhFailure] carrying Postgres's own sentence; nothing here rewrites it.
  Future<void> complete(BoardCard card) async {
    final move = StageTransition.after(card.columnStage);
    if (move == null) {
      throw RuleViolation(
        message: '${card.columnStage.label} is the last stage on the rail. Nothing follows it.',
        code: 'stage_terminal',
      );
    }
    // A second press while the first is open would write two transitions for one intent.
    if (state.containsKey(card.jobId)) return;

    state = Map<String, PendingMove>.unmodifiable(<String, PendingMove>{
      ...state,
      card.jobId: PendingMove(jobId: card.jobId, from: move.from, to: move.to),
    });

    try {
      await ref.read(jobRepositoryProvider).completeStage(
            jobId: card.jobId,
            stage: move.from,
          );
    } on Object {
      _clear(card.jobId);
      rethrow;
    }

    // The rail decides where the job actually landed, so the optimistic position is replaced by
    // a confirmed read rather than trusted. Only then is the override dropped — clearing it
    // first would flash the card back into the column it has just left.
    ref.invalidate(liveProductionBoardProvider);
    try {
      await ref.read(liveProductionBoardProvider.future);
    } on Object {
      // A failed re-read does not un-complete the stage. Drop the override and let the board's
      // own error state explain the read.
    } finally {
      _clear(card.jobId);
    }
  }

  void _clear(String jobId) {
    final next = <String, PendingMove>{...state}..remove(jobId);
    state = Map<String, PendingMove>.unmodifiable(next);
  }
}
