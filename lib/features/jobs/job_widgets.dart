/// The pieces the four job surfaces share: the live pulse, a person chip, the two dialogs every
/// irreversible action goes through, and the job's file list.
///
/// They sit in one file because the alternative is three near-identical copies. The mockups had
/// exactly that problem — "In Production" was a literal class list on one screen and a different
/// literal on the next, and the same state wore three colours across the corpus.
///
/// Two rules are encoded here rather than repeated at each call site:
///
///  * **A destructive action is confirmed, and a reason is typed.** D-006 added `on_hold`,
///    `cancelled` and `rework` because every gate in the mockups was one-way. Each writes to an
///    append-only audit log, so each owes that log a sentence. [promptForText] will not return
///    until one exists — the same asymmetry D-011 rule 2 applies to a CAD rejection.
///  * **A server refusal reaches the operator verbatim.** The D-011 rules are Postgres
///    `check_violation` messages already written from the operator's side; [showFailure] prints
///    `DhFailure.message` as it arrived and never wraps it in an apology.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

part 'job_widgets.g.dart';

// ================================================================= job files

/// Every file on a job, newest first, kept live.
///
/// `job_detail` counted "12 project files" with nothing behind the number, and the thumbnails it
/// did draw pointed at remote Google URLs. These are the real `attachments` rows, re-read whenever
/// one lands — which is what makes a photo uploaded from the shop floor appear on the engineer's
/// screen without a pull-to-refresh.
@riverpod
Stream<List<Attachment>> jobFiles(Ref ref, String jobId) {
  final store = ref.watch(attachmentStoreProvider);
  return liveQuery<List<Attachment>>(
    client: ref.watch(supabaseProvider),
    channelName: 'job-files:$jobId',
    tables: [LiveTable(table: 'attachments', column: 'job_id', value: jobId)],
    read: () => store.forJob(jobId),
  ).map((live) => live.data);
}

/// Signed thumbnail URLs for the images among them, keyed by attachment id.
///
/// Signed, never public: a public URL outlives the session, the job and the customer
/// relationship. Files that cannot be signed are simply absent, so one bad object does not blank
/// the gallery.
@riverpod
Future<Map<String, String>> jobFileUrls(Ref ref, String jobId) async {
  final files = await ref.watch(jobFilesProvider(jobId).future);
  final images = [for (final file in files) if (file.isImage) file];
  if (images.isEmpty) return const <String, String>{};
  return ref.watch(attachmentStoreProvider).signedUrls(images);
}

/// Map an `attachments` row onto what [AttachmentTile] draws.
AttachmentView attachmentViewOf(Attachment file, {String? signedUrl}) => AttachmentView(
      id: file.id,
      kind: file.kind,
      filename: file.filename,
      meta: file.metaLabel,
      durationLabel: file.durationLabel,
      thumbnail: signedUrl == null ? null : NetworkImage(signedUrl),
    );

// ================================================================= live pulse

/// The "Live Updates" chip — and the one thing that makes it honest.
///
/// `job_detail` drew a pulsing green dot over a hardcoded list: a CSS animation with no socket
/// behind it. This takes its [status] from the same subscription that produced the rows, so the
/// chip cannot read Live while the list is stale. Under reduced motion the dot is drawn solid
/// rather than removed — the state still has to be legible.
final class LivePulse extends StatefulWidget {
  const LivePulse({super.key, required this.status, this.dense = false});

  final LiveStatus status;
  final bool dense;

  @override
  State<LivePulse> createState() => _LivePulseState();
}

class _LivePulseState extends State<LivePulse> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(LivePulse old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) _syncAnimation();
  }

  void _syncAnimation() {
    final animate = widget.status == LiveStatus.live && !MediaQuery.disableAnimationsOf(context);
    if (animate) {
      if (!_blink.isAnimating) _blink.repeat(reverse: true);
    } else if (_blink.isAnimating) {
      _blink
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final (Color colour, String label) = switch (widget.status) {
      LiveStatus.live => (dh.success, 'Live'),
      LiveStatus.connecting => (scheme.onSurfaceVariant, 'Connecting'),
      LiveStatus.retrying => (dh.goldText, 'Reconnecting'),
      LiveStatus.offline => (scheme.error, 'Offline'),
    };

    final dot = AnimatedBuilder(
      animation: _blink,
      builder: (context, _) {
        final alpha = widget.status == LiveStatus.live ? 0.45 + 0.55 * _blink.value : 1.0;
        return Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: colour.withValues(alpha: alpha),
            shape: BoxShape.circle,
          ),
        );
      },
    );

    return Tooltip(
      message: switch (widget.status) {
        LiveStatus.live => 'This screen is subscribed. Changes appear as they happen.',
        LiveStatus.connecting => 'Opening the live connection.',
        LiveStatus.retrying => 'The live connection dropped. Reconnecting.',
        LiveStatus.offline => 'No live connection. Pull down to refresh.',
      },
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: widget.dense ? Spacing.sm : Spacing.sm + Spacing.xs,
          vertical: widget.dense ? 3 : 5,
        ),
        decoration: BoxDecoration(
          color: dh.surfaceContainerHigh,
          borderRadius: Radii.rFull,
          border: Border.all(color: dh.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dot,
            const SizedBox(width: Spacing.xs + 2),
            Text(
              label.toUpperCase(),
              style: context.text.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontSize: widget.dense ? 9.5 : 10.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================= people

enum AvatarTone { neutral, accent, gold }

/// An initials disc. D-008: the label is always a name that came off a real row — this widget has
/// no default and renders a question mark rather than inventing one.
final class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.name,
    this.size = 32,
    this.tone = AvatarTone.neutral,
  });

  final String? name;
  final double size;
  final AvatarTone tone;

  static String initialsOf(String? name) {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return '?';
    final parts = trimmed.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final single = parts.first;
      return (single.length > 1 ? single.substring(0, 2) : single).toUpperCase();
    }
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final (Color background, Color foreground) = switch (tone) {
      AvatarTone.neutral => (dh.surfaceContainerHigh, scheme.onSurfaceVariant),
      AvatarTone.accent => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      AvatarTone.gold => (dh.gold.withValues(alpha: 0.18), dh.goldText),
    };

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        initialsOf(name),
        style: AppTheme.mono(
          size: size * 0.36,
          weight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
}

// ================================================================= dialogs

/// A yes/no gate on something that cannot be undone.
///
/// The cancel label is deliberately the *safe* sentence rather than the word "Cancel" — on a
/// screen whose primary action is also called "Cancel job", a button reading "Cancel" is ambiguous
/// at exactly the wrong moment.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Leave it as it is',
  bool destructive = false,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message, style: dialogContext.text.bodyMedium),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: dialogContext.scheme.error,
                  foregroundColor: dialogContext.scheme.onError,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// Ask for the sentence the audit trail will keep.
///
/// Returns the trimmed text, or null if the operator backed out. Submit stays shut while the field
/// is empty: `JobRepository.holdJob`, `cancelJob` and `markForRework` each refuse an empty reason
/// server-side, and a button that fires a guaranteed refusal is worse than a button that waits.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  required String message,
  required String fieldLabel,
  required String submitLabel,
  String? hint,
  bool destructive = false,
  int minLines = 3,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _TextPromptDialog(
      title: title,
      message: message,
      fieldLabel: fieldLabel,
      submitLabel: submitLabel,
      hint: hint,
      destructive: destructive,
      minLines: minLines,
    ),
  );
}

final class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.message,
    required this.fieldLabel,
    required this.submitLabel,
    required this.hint,
    required this.destructive,
    required this.minLines,
  });

  final String title;
  final String message;
  final String fieldLabel;
  final String submitLabel;
  final String? hint;
  final bool destructive;
  final int minLines;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  bool get _ready => _controller.text.trim().isNotEmpty;

  void _submit() {
    if (!_ready) return;
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.message,
              style: context.text.bodyMedium?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.md),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: widget.minLines,
              maxLines: widget.minLines + 3,
              textCapitalization: TextCapitalization.sentences,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: widget.fieldLabel,
                hintText: widget.hint,
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back'),
        ),
        FilledButton(
          onPressed: _ready ? _submit : null,
          style: widget.destructive
              ? FilledButton.styleFrom(
                  backgroundColor: context.scheme.error,
                  foregroundColor: context.scheme.onError,
                )
              : null,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }
}

// ================================================================= feedback

/// Show a failure in the server's own words.
///
/// The D-011 rules refuse with sentences Postgres already wrote for the operator — "A casting
/// photo is required before marking this stage complete". Those strings are the product; this
/// prints them unaltered and puts the SQLSTATE behind a "Why" button for whoever has to file the
/// bug.
void showFailure(BuildContext context, DhFailure failure) {
  final detail = failure.detail;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(failure.message),
        duration: const Duration(seconds: 6),
        action: detail == null
            ? null
            : SnackBarAction(
                label: 'Why',
                onPressed: () => unawaited(
                  showDialog<void>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: Text(failure.message),
                      content: SelectableText(
                        '${failure.code ?? failure.kind.name}\n\n$detail',
                        style: AppTheme.mono(size: 11.5),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
}

/// Confirm that something landed. Says what happened, never "Success".
void showDone(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
}

// ================================================================= small layout helpers

/// An uppercase mono section heading with an optional action, for the stretches of a screen that
/// are not inside a `DhSectionCard`.
final class SectionHeading extends StatelessWidget {
  const SectionHeading({super.key, required this.title, this.trailing, this.count});

  final String title;
  final Widget? trailing;

  /// Rendered monospaced beside the title — "PROJECT FILES  12".
  final int? count;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Row(
      children: [
        Text(
          title.toUpperCase(),
          style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (count != null) ...[
          const SizedBox(width: Spacing.sm),
          Text(
            '$count',
            style: AppTheme.mono(size: 11, weight: FontWeight.w600, color: scheme.onSurface),
          ),
        ],
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}
