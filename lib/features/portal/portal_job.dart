/// One order, as its owner sees it: where it has got to, what it will cost, the documents that
/// belong to them, and their own conversation with the workshop.
///
/// Three things are deliberately absent, and each was present in the corpus by accident:
///
///  * **The internal thread.** `job_detail` ran one feed for everybody, which made shop-floor
///    chatter customer-visible by default. Here the feed is the same `v_digital_thread` view, but
///    `thread_select` drops `is_internal` rows for a customer principal — so the client reads every
///    system event (the audit trail is what they are entitled to) and only the posts written for
///    them. The composer writes `is_internal: false` unconditionally, because a customer's own post
///    marked internal would be filtered back out and vanish in front of its author.
///  * **The vendor.** Who cast the piece is the workshop's business relationship, not the client's.
///  * **The mesh.** A CAD render is shared; the STL behind it is the workshop's design asset.
///    [PortalGateway.customerDocumentKinds] is where that line is drawn.
///
/// The rail is shown in full — all fourteen stages (D-002) — because a client watching their own
/// piece move through fourteen named steps is the honest version of a progress bar, and the
/// mockup's alternative was a six-step tracker that disagreed with the workshop's own vocabulary.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/thread_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/portal/portal_actions.dart';
import 'package:dhanaos/features/portal/portal_approvals.dart';
import 'package:dhanaos/features/portal/portal_gateway.dart';
import 'package:dhanaos/features/portal/portal_surface.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class PortalJobScreen extends ConsumerWidget {
  const PortalJobScreen({super.key, required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(portalJobViewProvider(jobId));

    return ClientSurface(
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoadingSkeleton(height: 28, width: 220),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.lines(count: 4),
            ],
          ),
        ),
        error: (error, _) => ErrorState(
          title: 'This order did not open',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not reach the workshop just now. Go back to your orders and try '
                  'again.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(portalJobViewProvider(jobId)),
        ),
        data: (view) => _Body(view: view),
      ),
    );
  }
}

// ================================================================= body

final class _Body extends ConsumerWidget {
  const _Body({required this.view});

  final PortalJobView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The approvals read is a convenience on this screen: a failure must not take the order down
    // with it, so only its value is used.
    final approvals = ref.watch(portalApprovalsProvider).valueOrNull;
    final mine = [
      for (final item in approvals?.outstanding ?? const <PortalApprovalItem>[])
        if (item.jobId == view.job.id) item,
    ];

    return RefreshIndicator(
      onRefresh: () async {
        ref
          ..invalidate(portalJobViewProvider(view.job.id))
          ..invalidate(portalApprovalsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xxl),
        children: [
          OrderLine(
            code: view.job.displayCode,
            title: view.job.displayTitle,
            trailing: StatusChip.job(view.job.status, dense: true),
          ),
          const SizedBox(height: Spacing.md),

          if (mine.isNotEmpty) ...[
            _WaitingOnYou(items: mine),
            const SizedBox(height: Spacing.md),
          ],

          _Progress(view: view),
          const SizedBox(height: Spacing.md),

          _Facts(view: view),
          const SizedBox(height: Spacing.md),

          if (view.outboundShipment != null) ...[
            _Delivery(shipment: view.outboundShipment!),
            const SizedBox(height: Spacing.md),
          ],

          _Documents(view: view),
          const SizedBox(height: Spacing.lg),

          _Conversation(jobId: view.job.id),
        ],
      ),
    );
  }
}

/// A decision standing between the piece and the next bench.
final class _WaitingOnYou extends StatelessWidget {
  const _WaitingOnYou({required this.items});

  final List<PortalApprovalItem> items;

  @override
  Widget build(BuildContext context) {
    final dh = context.dh;
    return DhCard(
      accent: dh.gold,
      onTap: () => unawaited(PortalApprovalsScreen.push(context)),
      child: Row(
        children: [
          Icon(Icons.pending_actions_outlined, size: 20, color: dh.goldText),
          const SizedBox(width: Spacing.sm + Spacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  items.length == 1
                      ? '${items.single.kind.label} is waiting on you'
                      : '${items.length} decisions are waiting on you',
                  style: context.text.titleMedium?.copyWith(color: context.scheme.onSurface),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  items.length == 1
                      ? items.single.kind.blurb
                      : 'The workshop holds the piece here until you decide.',
                  style: context.text.bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: context.scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

// ================================================================= progress

final class _Progress extends StatelessWidget {
  const _Progress({required this.view});

  final PortalJobView view;

  @override
  Widget build(BuildContext context) {
    return DhSectionCard(
      title: 'Where it is',
      leading: const Icon(Icons.timeline_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PortalPhaseBar(
            phase: view.phase,
            progress: view.progress,
            paused: view.job.status == JobStatus.onHold,
            note: view.nextStepLabel,
          ),
          const SizedBox(height: Spacing.md),
          // D-002's fourteen stages, in the workshop's own vocabulary.
          JobStageRail(nodes: _railNodes(view)),
        ],
      ),
    );
  }

  /// The 14 rail nodes. Built here rather than on [PortalJobView] because [StageNode] belongs to
  /// the component set, and a read model that returned one would make the data layer depend on the
  /// widget layer.
  ///
  /// No dwell figures and no late flags: "4d at casting" is a number a client reads as a
  /// complaint, and the workshop's internal pace is not a promise anyone made them. An unseeded
  /// rail falls back to the single known position so it cannot read as complete.
  static List<StageNode> _railNodes(PortalJobView view) {
    if (view.rail.isEmpty) {
      return StageNode.railFor(
        active: view.job.currentStage ?? LifecycleStage.inquiry,
        blocked: view.job.status == JobStatus.onHold,
      );
    }
    return [
      for (final row in view.rail.stages) StageNode(stage: row.stage, state: row.state),
    ];
  }
}

// ================================================================= the facts

final class _Facts extends StatelessWidget {
  const _Facts({required this.view});

  final PortalJobView view;

  static final _day = DateFormat('d MMM yyyy');

  @override
  Widget build(BuildContext context) {
    final due = view.dueDate;
    final agreed = view.agreedTotal;
    final certificate = view.certificate;

    return DhCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DataPairGrid(
            columns: 2,
            children: [
              DataPair.mono(
                label: 'Order',
                value: view.job.displayCode,
                emphasis: DataEmphasis.strong,
              ),
              DataPair.mono(
                label: 'Expected',
                value: due == null ? DataPair.placeholder : _day.format(due.toLocal()),
                icon: Icons.event_outlined,
              ),
              if (view.job.category != null)
                DataPair(
                  label: 'Piece',
                  value: [
                    view.job.subStyle?.label,
                    view.job.category!.label,
                  ].whereType<String>().join(' · '),
                ),
              if (view.job.quantity > 1)
                DataPair.mono(label: 'Pieces', value: '${view.job.quantity}'),
              // D-004: money is `Money` in minor units, formatted with Indian grouping when the
              // quote is in INR. Absent until a price is agreed — an unpriced order shows nothing
              // rather than a zero.
              if (agreed != null)
                DataPair.money(
                  label: 'Agreed price',
                  amount: agreed,
                  emphasis: DataEmphasis.strong,
                ),
            ],
          ),
          if (certificate != null && certificate.isRequired) ...[
            const SizedBox(height: Spacing.md),
            Divider(height: 1, color: context.dh.outlineVariant),
            const SizedBox(height: Spacing.md),
            Row(
              children: [
                Expanded(
                  child: DataPair.mono(
                    label: '${certificate.lab.label} certificate',
                    value: certificate.certNumber ?? 'Not issued yet',
                  ),
                ),
                StatusChip.cert(certificate.status, dense: true),
              ],
            ),
          ],
          if (view.job.status == JobStatus.onHold) ...[
            const SizedBox(height: Spacing.md),
            const PortalNote(
              tone: PortalNoteTone.action,
              icon: Icons.pause_circle_outline_rounded,
              text: 'This order is paused. The workshop will be in touch about what they need '
                  'before it can carry on.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= delivery

/// The one leg a client is shown. The wax hop to a hub and the trip to the gem lab are the
/// workshop's logistics, and `PortalGateway` never fetches them.
final class _Delivery extends StatelessWidget {
  const _Delivery({required this.shipment});

  final Shipment shipment;

  @override
  Widget build(BuildContext context) {
    final waybill = shipment.waybill;

    return DhSectionCard(
      title: 'Delivery',
      leading: const Icon(Icons.local_shipping_outlined),
      action: StatusChip(
        label: shipment.status.label,
        dense: true,
        tone: switch (shipment.status) {
          ShipmentStatus.draft => ChipTone.neutral,
          ShipmentStatus.dispatched || ShipmentStatus.inTransit => ChipTone.accent,
          ShipmentStatus.delivered => ChipTone.success,
          ShipmentStatus.exception => ChipTone.danger,
        },
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DataPairGrid(
            columns: 2,
            children: [
              DataPair(label: 'Courier', value: shipment.courierLabel),
              DataPair.mono(
                label: 'Tracking',
                value: waybill == null || waybill.isEmpty
                    ? 'Not issued yet'
                    : waybill,
              ),
              if (shipment.dispatchedAt != null)
                DataPair.timestamp(label: 'Dispatched', utc: shipment.dispatchedAt!),
              if (shipment.deliveredAt != null)
                DataPair.timestamp(label: 'Delivered', utc: shipment.deliveredAt!),
            ],
          ),
          if (shipment.receivedBy != null) ...[
            const SizedBox(height: Spacing.md),
            DataPair(label: 'Signed for by', value: shipment.receivedBy!),
          ],
        ],
      ),
    );
  }
}

// ================================================================= documents

/// The files that belong to the client.
///
/// `job_detail` counted "12 project files" with nothing behind the number and pointed its
/// thumbnails at remote Google URLs that will rot. These are real `attachments` rows, filtered to
/// the kinds a retailer may have, with links signed for thirty minutes at a time.
final class _Documents extends ConsumerWidget {
  const _Documents({required this.view});

  final PortalJobView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final documents = view.documents;
    final images = [for (final file in documents) if (file.isImage) file];
    final others = [for (final file in documents) if (!file.isImage) file];

    return DhSectionCard(
      title: 'Your documents',
      leading: const Icon(Icons.folder_outlined),
      subtitle: documents.isEmpty
          ? null
          : 'Tap a file to copy a download link. Links expire after 30 minutes.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (documents.isEmpty)
            const EmptyState(
              compact: true,
              icon: Icons.folder_off_outlined,
              title: 'Nothing to download yet',
              message: 'Renders, your certificate and your invoice appear here as the workshop '
                  'issues them.',
            )
          else ...[
            if (images.isNotEmpty) ...[
              AttachmentGrid(
                items: [
                  for (final file in images)
                    AttachmentView(
                      id: file.id,
                      kind: file.kind,
                      filename: file.filename,
                      meta: file.metaLabel,
                      thumbnail: _thumb(view.documentUrls[file.id]),
                    ),
                ],
                onOpen: (item) => unawaited(_copyLink(context, ref, documents, item.id)),
              ),
              if (others.isNotEmpty) const SizedBox(height: Spacing.md),
            ],
            for (final file in others) ...[
              AttachmentTile.row(
                item: AttachmentView(
                  id: file.id,
                  kind: file.kind,
                  filename: file.filename,
                  meta: file.metaLabel,
                  durationLabel: file.durationLabel,
                ),
                onOpen: () => unawaited(_copyLink(context, ref, documents, file.id)),
              ),
              const SizedBox(height: Spacing.sm),
            ],
          ],
        ],
      ),
    );
  }

  static ImageProvider? _thumb(String? url) =>
      url == null || url.isEmpty ? null : NetworkImage(url);

  /// Signed, never public: a public URL outlives the session, the order and the relationship. The
  /// viewer sandbox has no share sheet here, so the clipboard is the honest affordance.
  Future<void> _copyLink(
    BuildContext context,
    WidgetRef ref,
    List<Attachment> documents,
    String attachmentId,
  ) async {
    Attachment? file;
    for (final candidate in documents) {
      if (candidate.id == attachmentId) file = candidate;
    }
    if (file == null) return;

    try {
      final url = await ref.read(attachmentStoreProvider).signedUrl(file);
      await Clipboard.setData(ClipboardData(text: url));
      if (!context.mounted) return;
      showDone(context, 'Link copied. It opens in a browser and expires in 30 minutes.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }
}

// ================================================================= the conversation

/// The client's half of the digital thread.
///
/// The same `v_digital_thread` union the workshop reads — system events interleaved with human
/// posts — but `thread_select` removes every `is_internal` row for a customer principal, so this
/// renders the audit trail plus the posts written for them and nothing else. That filtering is
/// Postgres's, not this widget's; what this widget guarantees is the other direction, that a post
/// the client writes is never marked internal.
final class _Conversation extends ConsumerStatefulWidget {
  const _Conversation({required this.jobId});

  final String jobId;

  @override
  ConsumerState<_Conversation> createState() => _ConversationState();
}

class _ConversationState extends ConsumerState<_Conversation> {
  final TextEditingController _body = TextEditingController();

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
    final thread = ref.watch(jobThreadLiveProvider(widget.jobId));
    final me = ref.watch(currentUserProvider).valueOrNull;
    final busy = ref.watch(portalComposerProvider(widget.jobId)).isLoading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(
          title: 'Messages and updates',
          trailing: switch (thread) {
            AsyncValue(value: final live?) => LivePulse(status: live.status, dense: true),
            _ => null,
          },
        ),
        const SizedBox(height: Spacing.sm + Spacing.xs),
        DhCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // D-008: the client's own name, off the session row.
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
                        hintText: 'Ask the workshop something about this order',
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
              const SizedBox(height: Spacing.sm),
              Row(
                children: [
                  // No visibility toggle. Everything a client writes here is read by the workshop;
                  // there is no "team only" for somebody who is not on the team.
                  Expanded(
                    child: Text(
                      'The workshop sees everything you write here.',
                      style: context.text.bodySmall
                          ?.copyWith(color: context.scheme.onSurfaceVariant),
                    ),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: _ready && !busy ? () => unawaited(_send()) : null,
                    icon: busy
                        ? const PortalSpinner()
                        : const Icon(Icons.send_rounded, size: 16),
                    label: const Text('Send'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        switch (thread) {
          AsyncValue(value: final live?) => _entries(context, live.data),
          AsyncError(error: final error) => ErrorState(
              compact: true,
              title: 'The updates did not load',
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

  Widget _entries(BuildContext context, List<ThreadEntry> chronological) {
    if (chronological.isEmpty) {
      return const EmptyState(
        compact: true,
        icon: Icons.forum_outlined,
        title: 'Nothing here yet',
        message: 'Every step the workshop completes lands here automatically. Ask the first '
            'question to start the conversation.',
      );
    }
    final entries = [...chronological]..sort(ThreadEntry.newestFirst);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries) ...[
          _Entry(entry: entry, viewerId: ref.watch(currentUserProvider).valueOrNull?.id),
          const SizedBox(height: Spacing.sm),
        ],
      ],
    );
  }

  /// No `stage` is sent with the post. Tagging a client's message with the workshop's current
  /// stage would file their words under a vocabulary they did not use; an internal post carries a
  /// stage because the shop floor thinks in stages, and a client does not.
  Future<void> _send() async {
    final failure =
        await ref.read(portalComposerProvider(widget.jobId).notifier).post(_body.text);
    if (!mounted) return;
    if (failure != null) {
      showFailure(context, failure);
      return;
    }
    setState(_body.clear);
  }
}

/// One row of the thread. An event is a quiet system line; a post is a card with a name on it.
final class _Entry extends StatelessWidget {
  const _Entry({required this.entry, required this.viewerId});

  final ThreadEntry entry;
  final String? viewerId;

  static final _when = DateFormat('d MMM · HH:mm');

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final stamp = _when.format(entry.createdAt.toLocal());
    final mine = entry.actorId != null && entry.actorId == viewerId;

    // The sealed union is what makes this exhaustive: a third entry kind added to
    // `v_digital_thread` becomes a compile error here rather than a silently blank row. Each
    // branch binds what it reads, because a pattern match does not promote an instance field.
    return switch (entry) {
      ThreadEventEntry(:final activityKind, :final body) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_eventIcon(activityKind), size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  body,
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Text(stamp, style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ThreadPostEntry(:final actorLabel, :final body) => DhCard(
          tone: DhCardTone.inset,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  PersonAvatar(
                    name: actorLabel,
                    size: 24,
                    tone: mine ? AvatarTone.accent : AvatarTone.neutral,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      mine ? 'You' : entry.actorDisplay,
                      style: context.text.bodySmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(stamp, style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Text(body, style: context.text.bodyMedium),
            ],
          ),
        ),
    };
  }

  static IconData _eventIcon(ActivityKind? kind) => switch (kind) {
        ActivityKind.approved => Icons.check_circle_outline_rounded,
        ActivityKind.rejected => Icons.cancel_outlined,
        ActivityKind.fileUploaded => Icons.attach_file_rounded,
        ActivityKind.jobCreated => Icons.play_circle_outline_rounded,
        ActivityKind.exceptionRaised => Icons.report_problem_outlined,
        ActivityKind.stageChanged => Icons.trending_flat_rounded,
        _ => Icons.circle_outlined,
      };
}
