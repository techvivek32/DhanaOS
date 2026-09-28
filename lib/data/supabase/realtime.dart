/// Live job and thread updates — the part the mockups only mimed.
///
/// `job_detail_dh_1048` drew a pulsing green dot labelled "Live Updates" and `certification`
/// titled its feed "Live Thread". Neither had a socket behind it: the dot was a CSS animation
/// on a static div and the feed was hardcoded list items. This file makes both honest.
///
/// Two things are exposed:
///
///  * [watchTables] — the raw helper. One Postgres-changes channel covering several tables,
///    torn down when the last listener cancels.
///  * [jobFeedProvider] / [threadFeedProvider] — that stream folded into a [LiveFeed], which
///    carries *both* the connection status (the pulse) and the latest row change (the feed).
///    One channel drives both, so the dot cannot claim "Live" while the list is stale.
///
/// **Database prerequisite.** Postgres only publishes what the replication publication names:
///
/// ```sql
/// alter publication supabase_realtime
///   add table jobs, job_stages, activity_events, thread_posts, attachments;
/// ```
///
/// Without that the channel subscribes cleanly and simply never delivers a row — which is why
/// [LiveFeed.changes] is surfaced: a feed that reports live and has counted nothing is the
/// symptom to look for.
///
/// RLS still applies to realtime: a partner receives changes only for jobs with a stage
/// assigned to that partner (D-008). Nothing here re-checks that, because the client is not
/// where scoping is decided.
library;

import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';

part 'realtime.g.dart';

// ---------------------------------------------------------------- what to watch

/// One table on a channel, optionally narrowed to a single job.
final class LiveTable {
  const LiveTable({
    required this.table,
    this.column,
    this.value,
    this.event = PostgresChangeEvent.all,
  }) : assert(
          (column == null) == (value == null),
          'A filter needs both a column and a value.',
        );

  final String table;

  /// Server-side filter column — `id` on `jobs`, `job_id` on everything hanging off it.
  /// Filtering here rather than in Dart keeps another job's traffic off the socket.
  final String? column;
  final Object? value;

  final PostgresChangeEvent event;

  PostgresChangeFilter? get filter {
    final on = column;
    if (on == null) return null;
    return PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: on,
      value: value,
    );
  }

  /// Everything `job_detail` renders: the job row, its stage rail, its audit trail, its thread
  /// and its files. `activity_events` has update and delete revoked (0003_job_spine.sql), so
  /// insert is the only event it can ever raise.
  static List<LiveTable> forJob(String jobId) => [
        LiveTable(table: 'jobs', column: 'id', value: jobId),
        LiveTable(table: 'job_stages', column: 'job_id', value: jobId),
        LiveTable(
          table: 'activity_events',
          column: 'job_id',
          value: jobId,
          event: PostgresChangeEvent.insert,
        ),
        LiveTable(table: 'thread_posts', column: 'job_id', value: jobId),
        LiveTable(table: 'attachments', column: 'job_id', value: jobId),
      ];

  /// The digital thread on its own: human posts interleaved with system events.
  static List<LiveTable> forThread(String jobId) => [
        LiveTable(table: 'thread_posts', column: 'job_id', value: jobId),
        LiveTable(
          table: 'activity_events',
          column: 'job_id',
          value: jobId,
          event: PostgresChangeEvent.insert,
        ),
      ];
}

// ---------------------------------------------------------------- what comes back

/// A row changed. Transport details are dropped; what remains is what a repository needs to
/// decide whether to patch its cache or refetch.
final class RealtimeChange {
  const RealtimeChange({
    required this.table,
    required this.event,
    required this.row,
    required this.previous,
    required this.at,
  });

  factory RealtimeChange.fromPayload(PostgresChangePayload payload) => RealtimeChange(
        table: payload.table,
        event: payload.eventType,
        // A delete carries only the old record, and only its replica-identity columns.
        row: payload.eventType == PostgresChangeEvent.delete
            ? payload.oldRecord
            : payload.newRecord,
        previous: payload.oldRecord,
        at: payload.commitTimestamp,
      );

  final String table;
  final PostgresChangeEvent event;
  final Map<String, dynamic> row;
  final Map<String, dynamic> previous;

  /// Commit time, UTC as Postgres sent it. Convention 7: render in local time, never store the
  /// converted value.
  final DateTime at;

  String? get id => row['id'] as String?;

  bool get isDelete => event == PostgresChangeEvent.delete;
  bool get isInsert => event == PostgresChangeEvent.insert;
}

/// Connection state behind the "Live Updates" dot.
enum LiveStatus {
  connecting('Connecting'),
  live('Live'),
  retrying('Reconnecting'),
  offline('Offline');

  const LiveStatus(this.label);

  final String label;
}

/// One event off a channel: either the connection changed, or a row did.
sealed class LiveEvent {
  const LiveEvent();
}

final class LiveStatusChanged extends LiveEvent {
  const LiveStatusChanged(this.status, {this.failure});

  final LiveStatus status;

  /// Set when the socket reported an error rather than a clean close.
  final DhFailure? failure;
}

final class LiveRowChanged extends LiveEvent {
  const LiveRowChanged(this.change);

  final RealtimeChange change;
}

/// [LiveEvent]s folded into the shape a screen actually binds to.
final class LiveFeed {
  const LiveFeed({
    required this.status,
    this.lastChange,
    this.changes = 0,
    this.failure,
  });

  final LiveStatus status;

  /// The most recent row change, or null while nothing has moved.
  final RealtimeChange? lastChange;

  /// How many row changes this subscription has delivered. A feed that reports [isLive] and
  /// never increments this is the signature of a table missing from the `supabase_realtime`
  /// publication.
  final int changes;

  final DhFailure? failure;

  bool get isLive => status == LiveStatus.live;

  /// What the pulse chip reads. The dot is only green at [LiveStatus.live].
  String get pulseLabel => switch (status) {
        LiveStatus.live => 'Live',
        LiveStatus.connecting => 'Connecting…',
        LiveStatus.retrying => 'Reconnecting…',
        LiveStatus.offline => 'Offline — pull to refresh',
      };

  LiveFeed apply(LiveEvent event) => switch (event) {
        LiveStatusChanged(status: final next, failure: final why) => LiveFeed(
            status: next,
            lastChange: lastChange,
            changes: changes,
            failure: why,
          ),
        LiveRowChanged(:final change) => LiveFeed(
            status: status,
            lastChange: change,
            changes: changes + 1,
            failure: failure,
          ),
      };
}

// ---------------------------------------------------------------- the helper

/// Realtime topics must be unique per subscription — `subscribe()` throws if it is called
/// twice on one channel instance, and two screens can legitimately watch the same job.
int _channelSeq = 0;

/// Subscribe to Postgres changes on [tables] over a single channel.
///
/// The channel is created on first listen and removed on cancel, so a job screen that is popped
/// stops paying for a socket. Socket trouble is delivered as [LiveStatusChanged] rather than as
/// a stream error: a dropped connection is a degraded state the UI should show, not a failure
/// that should tear the screen down.
Stream<LiveEvent> watchTables(
  SupabaseClient client, {
  required String channelName,
  required List<LiveTable> tables,
  String schema = 'public',
}) {
  late final StreamController<LiveEvent> controller;
  RealtimeChannel? channel;

  void emit(LiveEvent event) {
    if (!controller.isClosed) controller.add(event);
  }

  void start() {
    var built = client.channel('$channelName#${_channelSeq++}');
    for (final table in tables) {
      built = built.onPostgresChanges(
        event: table.event,
        schema: schema,
        table: table.table,
        filter: table.filter,
        callback: (payload) => emit(LiveRowChanged(RealtimeChange.fromPayload(payload))),
      );
    }
    channel = built;
    emit(const LiveStatusChanged(LiveStatus.connecting));

    built.subscribe((status, error) {
      switch (status) {
        case RealtimeSubscribeStatus.subscribed:
          emit(const LiveStatusChanged(LiveStatus.live));
        case RealtimeSubscribeStatus.channelError:
        case RealtimeSubscribeStatus.timedOut:
          // The client retries on its own, so this is "reconnecting", not "dead".
          emit(LiveStatusChanged(
            LiveStatus.retrying,
            failure: error == null ? null : toDhFailure(error),
          ));
        case RealtimeSubscribeStatus.closed:
          emit(const LiveStatusChanged(LiveStatus.offline));
      }
    });
  }

  Future<void> stop() async {
    final open = channel;
    channel = null;
    if (open != null) {
      try {
        await client.removeChannel(open);
      } on Object catch (_) {
        // The socket was already gone. Nothing to unwind.
      }
    }
    if (!controller.isClosed) await controller.close();
  }

  controller = StreamController<LiveEvent>(onListen: start, onCancel: stop);
  return controller.stream;
}

/// [watchTables], folded. Starts at [LiveStatus.connecting] so the dot is never green before
/// the socket says so.
Stream<LiveFeed> watchFeed(
  SupabaseClient client, {
  required String channelName,
  required List<LiveTable> tables,
}) async* {
  var feed = const LiveFeed(status: LiveStatus.connecting);
  yield feed;
  await for (final event in watchTables(
    client,
    channelName: channelName,
    tables: tables,
  )) {
    feed = feed.apply(event);
    yield feed;
  }
}

// ---------------------------------------------------------------- providers

/// Everything `job_detail` shows for one job, live. Auto-disposes: leaving the screen closes
/// the channel.
@riverpod
Stream<LiveFeed> jobFeed(Ref ref, String jobId) => watchFeed(
      ref.watch(supabaseProvider),
      channelName: 'job:$jobId',
      tables: LiveTable.forJob(jobId),
    );

/// The digital thread alone, for surfaces that render the conversation without the rail.
@riverpod
Stream<LiveFeed> threadFeed(Ref ref, String jobId) => watchFeed(
      ref.watch(supabaseProvider),
      channelName: 'thread:$jobId',
      tables: LiveTable.forThread(jobId),
    );
