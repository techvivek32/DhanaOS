/// The signature mechanic: one chronological stream carrying both what the system did and what
/// people said about it.
///
/// `job_detail` is where this came from — "Stage Changed: Casting — System updated status
/// automatically" sitting in the same feed as a colleague's remark — and `certification` called
/// the same surface an "Immutable Audit Trail". Neither had anything behind it: the list was
/// hardcoded, the "Live Updates" dot was a CSS animation with no socket, and there was no composer
/// anywhere in the 46 screens.
///
/// Three things are made true here.
///
///  * **One stream, not two tabs.** `v_digital_thread` unions `activity_events` with
///    `thread_posts`, and [ThreadEntry] is a sealed union over the result, so a single list renders
///    both and a third entry kind added later is a compile error rather than a silent blank row.
///  * **The pulse is the subscription.** The chip reads its status from the same [Live] value that
///    produced the rows, so it cannot say Live over a stale list.
///  * **Internal by default.** The mockups ran one feed for everybody, which made shop-floor
///    chatter customer-visible by default. A new post starts internal and has to be deliberately
///    opened up; events are never internal, because the audit trail is what the customer is
///    entitled to see.
///
/// Editing is not offered. `activity_events` has UPDATE and DELETE revoked in Postgres, and a post
/// that can be rewritten without a trace is not evidence of anything — `ThreadRepository.editPost`
/// exists for an author's own correction and stamps `edited_at` when it is used.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/thread_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

part 'digital_thread.g.dart';

/// A file chosen but not yet posted. Held locally so the operator can stage three photos and one
/// sentence, then send them as one entry.
@immutable
final class PendingFile {
  const PendingFile({
    required this.path,
    required this.filename,
    required this.kind,
    this.sizeBytes,
  });

  final String path;
  final String filename;
  final AttachmentKind kind;
  final int? sizeBytes;

  /// Routing by extension. The operator says what the file *is* only when the guess is wrong —
  /// which on a shop floor is almost never, because what gets attached to a thread is a photo.
  static AttachmentKind kindFor(String filename) {
    final dot = filename.lastIndexOf('.');
    final ext = dot <= 0 ? '' : filename.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'png' || 'jpg' || 'jpeg' || 'webp' || 'heic' => AttachmentKind.referenceImage,
      'wav' || 'm4a' || 'aac' || 'mp3' || 'ogg' => AttachmentKind.voiceNote,
      'stl' || 'step' || 'stp' || '3dm' || 'obj' => AttachmentKind.stl,
      'pdf' => AttachmentKind.certificatePdf,
      _ => AttachmentKind.other,
    };
  }
}

// ================================================================= composer controller

/// Posting: one `thread_posts` row, then its files.
///
/// The order matters. `attachments.thread_id` is a foreign key onto the post, so the post has to
/// exist before a file can point at it — which also means a failed upload leaves the sentence
/// standing rather than throwing away what the operator typed.
@riverpod
class ThreadComposer extends _$ThreadComposer {
  @override
  FutureOr<void> build(String jobId) {}

  /// Returns the failure to show, or null when the post landed. A file that failed to upload is
  /// reported as a failure even though the post itself succeeded — silently dropping an attachment
  /// is how a casting photo goes missing.
  Future<DhFailure?> post({
    required String body,
    required bool isInternal,
    LifecycleStage? stage,
    List<PendingFile> files = const [],
  }) async {
    state = const AsyncLoading<void>().copyWithPrevious(state);
    try {
      final post = await ref.read(threadRepositoryProvider).postMessage(
            jobId: jobId,
            body: body,
            stage: stage,
            isInternal: isInternal,
          );

      if (files.isNotEmpty) {
        final orgId = ref.read(repoIdentityProvider).requireOrgId();
        final store = ref.read(attachmentStoreProvider);
        for (final file in files) {
          await store.upload(
            UploadRequest.file(
              orgId: orgId,
              kind: file.kind,
              file: File(file.path),
              filename: file.filename,
              jobId: jobId,
              threadId: post.id,
            ),
          );
        }
        ref.invalidate(jobFilesProvider(jobId));
      }

      state = const AsyncData<void>(null);
      return null;
    } on Object catch (error, stack) {
      final failure = toDhFailure(error, stack);
      state = AsyncError<void>(failure, stack);
      return failure;
    }
  }
}

// ================================================================= the stream

/// The feed and its composer, sized to sit inside the job detail scroll view.
///
/// Newest first, because that is how `job_detail` ordered it and because the end of a long job's
/// narrative is the end anyone opens it for. Older entries stay one tap away rather than being
/// paged off — a thread with 300 rows belongs to a job that has been through rework, and hiding
/// that history would hide the reason.
final class DigitalThread extends ConsumerStatefulWidget {
  const DigitalThread({
    super.key,
    required this.jobId,
    this.stage,
    this.canPost = true,
    this.initialCount = 25,
  });

  final String jobId;

  /// Tags a new post with where the job stood when it was written, so a thread re-read six weeks
  /// later still says which stage the remark was about.
  final LifecycleStage? stage;

  final bool canPost;
  final int initialCount;

  @override
  ConsumerState<DigitalThread> createState() => _DigitalThreadState();
}

class _DigitalThreadState extends ConsumerState<DigitalThread> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final thread = ref.watch(jobThreadLiveProvider(widget.jobId));
    final files = ref.watch(jobFilesProvider(widget.jobId)).valueOrNull ?? const <Attachment>[];
    final urls = ref.watch(jobFileUrlsProvider(widget.jobId)).valueOrNull ?? const <String, String>{};

    final byThread = <String, List<Attachment>>{};
    for (final file in files) {
      final threadId = file.threadId;
      if (threadId != null) byThread.putIfAbsent(threadId, () => []).add(file);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(
          title: 'Digital Thread',
          trailing: switch (thread) {
            AsyncValue(value: final live?) => LivePulse(status: live.status, dense: true),
            _ => null,
          },
        ),
        const SizedBox(height: Spacing.sm + Spacing.xs),
        if (widget.canPost) ...[
          _Composer(jobId: widget.jobId, stage: widget.stage),
          const SizedBox(height: Spacing.md),
        ],
        switch (thread) {
          AsyncValue(value: final live?) =>
            _entries(context, live.data, byThread, urls),
          AsyncError(error: final error) => ErrorState(
              compact: true,
              title: 'The thread did not load',
              message: error is DhFailure
                  ? error.message
                  : 'Pull down to refresh. Nothing you have written has been lost.',
              detail: error is DhFailure ? error.detail : null,
              onRetry: () => ref.invalidate(jobThreadLiveProvider(widget.jobId)),
            ),
          _ => const LoadingSkeleton.list(count: 3),
        },
      ],
    );
  }

  Widget _entries(
    BuildContext context,
    List<ThreadEntry> chronological,
    Map<String, List<Attachment>> byThread,
    Map<String, String> urls,
  ) {
    if (chronological.isEmpty) {
      return const EmptyState(
        compact: true,
        icon: Icons.forum_outlined,
        title: 'Nothing on the thread yet',
        message: 'Every stage change lands here automatically. Post the first note to start the '
            'conversation around them.',
      );
    }

    final entries = [...chronological]..sort(ThreadEntry.newestFirst);
    final hidden = _showAll ? 0 : (entries.length - widget.initialCount).clamp(0, entries.length);
    final visible = hidden == 0 ? entries : entries.sublist(0, widget.initialCount);

    String? lastDay;
    final rows = <Widget>[];
    for (final entry in visible) {
      final day = _dayKey(entry.createdAt.toLocal());
      if (day != lastDay) {
        lastDay = day;
        rows
          ..add(const SizedBox(height: Spacing.sm))
          ..add(_DaySeparator(label: _dayLabel(entry.createdAt.toLocal())))
          ..add(const SizedBox(height: Spacing.sm));
      }
      rows.add(
        _ThreadTile(
          entry: entry,
          files: byThread[entry.id] ?? const <Attachment>[],
          urls: urls,
        ),
      );
      rows.add(const SizedBox(height: Spacing.sm));
    }

    if (hidden > 0) {
      rows.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _showAll = true),
            icon: const Icon(Icons.history_rounded, size: 18),
            label: Text('Show $hidden earlier ${hidden == 1 ? 'entry' : 'entries'}'),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  static String _dayKey(DateTime local) =>
      '${local.year}-${local.month}-${local.day}';

  static String _dayLabel(DateTime local) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final delta = today.difference(day).inDays;
    return switch (delta) {
      0 => 'Today',
      1 => 'Yesterday',
      _ => DateFormat('EEEE d MMMM yyyy').format(local),
    };
  }
}

// ================================================================= one entry

final class _ThreadTile extends StatelessWidget {
  const _ThreadTile({required this.entry, required this.files, required this.urls});

  final ThreadEntry entry;
  final List<Attachment> files;
  final Map<String, String> urls;

  /// The sealed union is what makes this exhaustive: a third entry kind added to
  /// `v_digital_thread` later becomes a compile error here rather than a blank row.
  @override
  Widget build(BuildContext context) => switch (entry) {
        final ThreadEventEntry event => _EventRow(entry: event),
        final ThreadPostEntry post => _PostCard(entry: post, files: files, urls: urls),
      };
}

/// A system row. Deliberately lighter than a post: it is the spine of the narrative, not the
/// conversation, and fourteen stage changes at the weight of a human remark is noise.
final class _EventRow extends StatelessWidget {
  const _EventRow({required this.entry});

  final ThreadEventEntry entry;

  static IconData _iconFor(ActivityKind? kind) => switch (kind) {
        ActivityKind.stageChanged => Icons.alt_route_rounded,
        ActivityKind.jobCreated => Icons.play_circle_outline_rounded,
        ActivityKind.assigned => Icons.person_add_alt_rounded,
        ActivityKind.fileUploaded => Icons.attach_file_rounded,
        ActivityKind.approved => Icons.check_circle_outline_rounded,
        ActivityKind.rejected => Icons.cancel_outlined,
        ActivityKind.comment => Icons.chat_bubble_outline_rounded,
        ActivityKind.exceptionRaised => Icons.error_outline_rounded,
        ActivityKind.system || null => Icons.settings_suggest_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final decision = entry.activityKind == ActivityKind.approved ||
        entry.activityKind == ActivityKind.rejected;
    final problem = entry.activityKind == ActivityKind.exceptionRaised ||
        entry.activityKind == ActivityKind.rejected;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: problem ? scheme.errorContainer : dh.surfaceContainerHigh,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            _iconFor(entry.activityKind),
            size: 15,
            color: problem ? scheme.onErrorContainer : scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: Spacing.sm + Spacing.xs),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.body,
                  style: context.text.bodyMedium?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: decision ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                if (entry.detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    entry.detail!,
                    style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: Spacing.xs),
                Row(
                  children: [
                    Text(
                      entry.actorDisplay,
                      style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Text(
                      DateFormat('HH:mm').format(entry.createdAt.toLocal()),
                      style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
                    ),
                    if (entry.stage != null) ...[
                      const SizedBox(width: Spacing.sm),
                      StatusChip.lifecycle(entry.stage!, dense: true),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A human post, with whatever was attached to it.
final class _PostCard extends StatelessWidget {
  const _PostCard({required this.entry, required this.files, required this.urls});

  final ThreadPostEntry entry;
  final List<Attachment> files;
  final Map<String, String> urls;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;

    return DhCard(
      tone: DhCardTone.inset,
      accent: entry.isInternal ? null : context.dh.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PersonAvatar(name: entry.actorLabel, size: 28),
              const SizedBox(width: Spacing.sm + Spacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.actorDisplay,
                      style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      DateFormat('d MMM · HH:mm').format(entry.createdAt.toLocal()),
                      style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (entry.stage != null) StatusChip.lifecycle(entry.stage!, dense: true),
              const SizedBox(width: Spacing.xs),
              StatusChip(
                label: entry.isInternal ? 'Internal' : 'Client sees this',
                dense: true,
                tone: entry.isInternal ? ChipTone.neutral : ChipTone.warning,
                icon: entry.isInternal ? Icons.lock_outline_rounded : Icons.visibility_outlined,
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          SelectableText(entry.body, style: context.text.bodyMedium),
          if (files.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            for (final file in files) ...[
              AttachmentTile.row(item: attachmentViewOf(file, signedUrl: urls[file.id])),
              const SizedBox(height: Spacing.xs),
            ],
          ],
        ],
      ),
    );
  }
}

final class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Row(
      children: [
        Expanded(child: Divider(color: context.dh.outlineVariant)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.sm + Spacing.xs),
          child: Text(
            label.toUpperCase(),
            style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(child: Divider(color: context.dh.outlineVariant)),
      ],
    );
  }
}

// ================================================================= composer

final class _Composer extends ConsumerStatefulWidget {
  const _Composer({required this.jobId, required this.stage});

  final String jobId;
  final LifecycleStage? stage;

  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer> {
  final TextEditingController _body = TextEditingController();
  final List<PendingFile> _staged = [];

  /// Internal by default. The mockups ran one feed for everybody, which made shop-floor chatter
  /// customer-visible by default — the wrong side to fail on.
  bool _internal = true;

  @override
  void initState() {
    super.initState();
    _body.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _body
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  bool get _ready => _body.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final busy = ref.watch(threadComposerProvider(widget.jobId)).isLoading;
    final me = ref.watch(currentUserProvider).valueOrNull;

    return DhCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // D-008: the operator's own name, off the session row. There is no other source.
              PersonAvatar(name: me?.fullName, size: 32),
              const SizedBox(width: Spacing.sm + Spacing.xs),
              Expanded(
                child: TextField(
                  controller: _body,
                  minLines: 2,
                  maxLines: 6,
                  enabled: !busy,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Add a note to this job',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ],
          ),
          if (_staged.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (final file in _staged)
                  InputChip(
                    avatar: const Icon(Icons.attach_file_rounded, size: 16),
                    label: Text(
                      file.filename,
                      style: AppTheme.mono(size: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                    onDeleted: busy ? null : () => setState(() => _staged.remove(file)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: Spacing.sm),
          Divider(height: 1, color: context.dh.outlineVariant),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              IconButton(
                onPressed: busy ? null : () => unawaited(_attachFromCamera()),
                tooltip: 'Take a photo',
                icon: const Icon(Icons.photo_camera_outlined, size: 20),
              ),
              IconButton(
                onPressed: busy ? null : () => unawaited(_attachFromFiles()),
                tooltip: 'Attach a file',
                icon: const Icon(Icons.attach_file_rounded, size: 20),
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: _VisibilityToggle(
                  internal: _internal,
                  enabled: !busy,
                  onChanged: (value) => setState(() => _internal = value),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              FilledButton(
                onPressed: busy || !_ready ? null : () => unawaited(_post()),
                style: FilledButton.styleFrom(minimumSize: const Size(96, 40)),
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Post'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _attachFromCamera() async {
    try {
      final shot = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 88,
      );
      if (shot == null || !mounted) return;
      setState(() {
        _staged.add(
          PendingFile(
            path: shot.path,
            filename: shot.name,
            kind: AttachmentKind.referenceImage,
          ),
        );
      });
    } on Object catch (error, stack) {
      if (!mounted) return;
      showFailure(context, toDhFailure(error, stack));
    }
  }

  Future<void> _attachFromFiles() async {
    try {
      // file_picker 13 made this a static that returns the list directly — an empty list is a
      // cancelled dialog, not a failure.
      final picked = await FilePicker.pickFiles();
      if (picked.isEmpty || !mounted) return;
      setState(() {
        for (final file in picked) {
          final path = file.path;
          // Android hands back a content:// uri for some providers, which has no local path and
          // nothing here can stream. Skipping it is better than staging a file that cannot upload.
          if (path == null) continue;
          _staged.add(
            PendingFile(
              path: path,
              filename: file.name,
              kind: PendingFile.kindFor(file.name),
              sizeBytes: file.lengthSync(),
            ),
          );
        }
      });
    } on Object catch (error, stack) {
      if (!mounted) return;
      showFailure(context, toDhFailure(error, stack));
    }
  }

  Future<void> _post() async {
    final body = _body.text.trim();
    final files = List<PendingFile>.unmodifiable(_staged);

    final failure = await ref.read(threadComposerProvider(widget.jobId).notifier).post(
          body: body,
          isInternal: _internal,
          stage: widget.stage,
          files: files,
        );
    if (!mounted) return;
    if (failure != null) {
      showFailure(context, failure);
      return;
    }
    setState(() {
      _body.clear();
      _staged.clear();
    });
  }
}

/// Who can read this post. Two words, not a checkbox: "internal" is a decision with consequences
/// on a customer portal, and a tick box next to a send button is not a decision anyone makes.
final class _VisibilityToggle extends StatelessWidget {
  const _VisibilityToggle({
    required this.internal,
    required this.enabled,
    required this.onChanged,
  });

  final bool internal;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: enabled ? () => onChanged(!internal) : null,
        borderRadius: Radii.rFull,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xs, horizontal: Spacing.xs),
          child: StatusChip(
            label: internal ? 'Team only' : 'Client sees this',
            tone: internal ? ChipTone.neutral : ChipTone.warning,
            icon: internal ? Icons.lock_outline_rounded : Icons.visibility_outlined,
            dense: true,
            tooltip: internal
                ? 'Only your workshop sees this post. Tap to share it with the client.'
                : 'This post appears in the client portal. Tap to keep it inside the workshop.',
          ),
        ),
      ),
    );
  }
}
