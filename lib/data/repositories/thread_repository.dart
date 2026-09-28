/// The digital thread: `v_digital_thread`, `thread_posts`, and the live subscription behind both.
///
/// This is `job_detail`'s core mechanic — system events and human posts in ONE chronological
/// stream, not two tabs. The view unions `activity_events` with `thread_posts` and the sealed
/// [ThreadEntry] keeps them distinguishable, so a single list can render both and adding a third
/// entry kind later is a compile error rather than a silent fall-through.
///
/// Two things the mockups only mimed are honest here:
///
///  * **The pulse.** `job_detail` drew a green "Live Updates" dot over a hardcoded list and
///    `certification` titled the same feed a "Live Thread". [watchThreadLive] returns the entries
///    and the socket status from one subscription, so the dot cannot read Live while the list is
///    stale.
///  * **Immutability.** `certification` called its feed an "Immutable Audit Trail". Postgres has
///    UPDATE and DELETE revoked on `activity_events`, so nothing in this file can edit one. Only
///    a human post can be edited, only by its author (`thread_edit_own`), and the edit is stamped.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'thread_repository.g.dart';

/// `v_digital_thread`'s columns. Named rather than `*` because the view unions two tables and a
/// column added to either side should not change what a thread costs to load.
const _threadColumns =
    'id, job_id, entry_type, sub_kind, actor_id, actor_label, stage, body, detail, '
    'is_internal, created_at';

final class ThreadRepository {
  const ThreadRepository(this._client, this._identity);

  final SupabaseClient _client;
  final RepoIdentity _identity;

  // ---------------------------------------------------------------- read

  /// The whole thread for one job, oldest first.
  ///
  /// Chronological is the storage order because the thread is a narrative — "Stage Changed:
  /// Casting" followed by "Caster delayed" reads forwards. A screen that wants the newest at the
  /// top sorts with `ThreadEntry.newestFirst`, which is one line and keeps the ordering rule on
  /// the model.
  ///
  /// [limit] caps a long-running job rather than paging it: a thread with 400 entries belongs to a
  /// job that has been through rework, and the end an operator wants is the recent one. So the
  /// newest [limit] rows are taken and then re-sorted forwards.
  Future<List<ThreadEntry>> fetchThread(String jobId, {int limit = 400}) async {
    final rows = await guard(
      () => _client
          .from('v_digital_thread')
          .select(_threadColumns)
          .eq('job_id', jobId)
          .order('created_at', ascending: false)
          .limit(limit),
    );

    final entries = [for (final row in rows) ThreadEntry.fromJson(row)]
      ..sort(ThreadEntry.oldestFirst);
    return List<ThreadEntry>.unmodifiable(entries);
  }

  /// [fetchThread], kept current, with the connection status attached.
  ///
  /// One channel covers `thread_posts` and `activity_events` — the two tables the view unions —
  /// so a stage completion (which writes an event by trigger) and a colleague's reply both land
  /// in the same stream.
  Stream<Live<List<ThreadEntry>>> watchThreadLive(
    String jobId, {
    int limit = 400,
  }) =>
      liveQuery<List<ThreadEntry>>(
        client: _client,
        channelName: 'thread:$jobId',
        tables: LiveTable.forThread(jobId),
        read: () => fetchThread(jobId, limit: limit),
        // Completing a stage writes the stage row and the event within milliseconds; one re-read
        // should cover both.
        settle: const Duration(milliseconds: 250),
      );

  /// The entries alone, for a feed with no pulse chip above it.
  Stream<List<ThreadEntry>> watchThread(String jobId, {int limit = 400}) =>
      watchThreadLive(jobId, limit: limit).map((live) => live.data);

  /// Just the human posts, for a surface that shows the conversation without the audit rows.
  Future<List<ThreadPost>> fetchPosts(String jobId, {int limit = 200}) async {
    final rows = await guard(
      () => _client
          .from('thread_posts')
          .select()
          .eq('job_id', jobId)
          .order('created_at', ascending: false)
          .limit(limit),
    );
    final posts = [for (final row in rows) ThreadPost.fromJson(row)]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return List<ThreadPost>.unmodifiable(posts);
  }

  // ---------------------------------------------------------------- write

  /// Post on the job.
  ///
  /// [isInternal] hides the post from the customer portal. RLS is what enforces that
  /// (`thread_select`), not this method — but the flag has to be set at the moment of writing,
  /// because the mockups ran one feed for everybody and shop-floor chatter was customer-visible
  /// with nothing to mark it otherwise.
  ///
  /// [stage] tags the post to where the job was when it was written, so a thread re-read six weeks
  /// later still says which stage the remark was about.
  ///
  /// `author_label` is the session user's own name (D-008 — there is no other source for a name on
  /// screen), stored alongside `author_id` so a feed renders without a join to `app_users`.
  Future<ThreadPost> postMessage({
    required String jobId,
    required String body,
    LifecycleStage? stage,
    bool isInternal = false,
  }) async {
    final text = body.trim();
    if (text.isEmpty) {
      throw const MissingRequiredField(
        message: 'Write something before posting.',
        code: 'post_body_empty',
      );
    }

    final row = await guard(
      () => _client
          .from('thread_posts')
          .insert({
            'job_id': jobId,
            'author_id': _identity.requireUserId(),
            'author_label': _identity.displayName,
            'stage': stage?.wire,
            'body': text,
            'is_internal': isInternal,
          })
          .select()
          .single(),
    );
    return ThreadPost.fromJson(row);
  }

  /// Correct a post. Only the author can — `thread_edit_own` restricts it — and the edit is
  /// stamped rather than silent, because a thread that can be rewritten without a trace is not
  /// evidence of anything.
  Future<ThreadPost> editPost({
    required String postId,
    required String body,
  }) async {
    final text = body.trim();
    if (text.isEmpty) {
      throw const MissingRequiredField(
        message: 'A post cannot be emptied. Write the correction, or delete the post.',
        code: 'post_body_empty',
      );
    }

    final row = await guard(
      () => _client
          .from('thread_posts')
          .update({'body': text, 'edited_at': encodeInstant(DateTime.now())})
          .eq('id', postId)
          .select()
          .single(),
    );
    return ThreadPost.fromJson(row);
  }

  /// Remove a post. Events cannot be removed — Postgres revoked DELETE on `activity_events` — so
  /// the audit trail keeps its shape whatever happens to the conversation around it.
  Future<void> deletePost(String postId) =>
      guard(() => _client.from('thread_posts').delete().eq('id', postId));

  /// The raw channel, for a surface that wants the pulse without the entries — a header chip on a
  /// screen whose body is already subscribed elsewhere.
  Stream<LiveFeed> watchConnection(String jobId) => watchFeed(
        _client,
        channelName: 'thread-pulse:$jobId',
        tables: LiveTable.forThread(jobId),
      );
}

// ================================================================= providers

@Riverpod(keepAlive: true)
ThreadRepository threadRepository(Ref ref) => ThreadRepository(
      ref.watch(supabaseProvider),
      ref.watch(repoIdentityProvider),
    );

/// The chronological thread for one job, live.
@riverpod
Stream<List<ThreadEntry>> jobThread(Ref ref, String jobId) =>
    ref.watch(threadRepositoryProvider).watchThread(jobId);

/// The same thread with the socket status attached, for the "Live Updates" chip.
@riverpod
Stream<Live<List<ThreadEntry>>> jobThreadLive(Ref ref, String jobId) =>
    ref.watch(threadRepositoryProvider).watchThreadLive(jobId);
