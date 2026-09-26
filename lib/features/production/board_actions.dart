/// The one path a stage move takes, and the sentence an operator reads when it is refused.
///
/// Every route into a transition — a drop on a column, the card menu, the phone layout's button —
/// funnels through [completeCardStage] so the four things that must happen cannot be forgotten at
/// one call site and remembered at another:
///
///  1. the permission check, with the reason shown rather than a dead control;
///  2. the confirm, because a transition writes an append-only audit row and cannot be undone
///     (D-005) — the mockups had no such gate anywhere, every one of them one-way;
///  3. the commit, optimistic and rolled back on failure;
///  4. the refusal, printed **verbatim**. `fn_complete_stage` raises "A casting photo is required
///     before marking this stage complete" (D-011 rule 1) and "QC cannot be authorized with 2
///     unchecked item(s)" (rule 3). Those strings are the product; nothing here paraphrases them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/dashboard_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/production/board_controller.dart';

// ================================================================= messages

/// A one-line notice. Errors hold longer, because a rule refusal is a paragraph worth reading.
void showBoardMessage(
  BuildContext context,
  String message, {
  bool isError = false,
}) {
  final scheme = context.scheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: context.text.bodyMedium?.copyWith(
            color: isError ? scheme.onErrorContainer : null,
          ),
        ),
        backgroundColor: isError ? scheme.errorContainer : null,
        duration: Duration(seconds: isError ? 8 : 3),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: isError,
      ),
    );
}

/// A failure, in the server's own words.
void showBoardFailure(BuildContext context, Object error) {
  final message = error is DhFailure
      ? error.message
      : 'The board could not reach the server. Check the shop Wi-Fi and try the move again — '
          'nothing has changed.';
  showBoardMessage(context, message, isError: true);
}

// ================================================================= confirm

/// The gate on an irreversible transition.
///
/// Both buttons name what they do. On a screen whose whole subject is moving work forward, a
/// button reading "Cancel" is ambiguous at exactly the wrong moment.
Future<bool> confirmStageMove(
  BuildContext context, {
  required BoardCard card,
  required StageTransition move,
}) async {
  final gate = move.serverGate;
  final answer = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Complete ${move.from.label}?'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              card.displayCode,
              style: AppTheme.mono(
                size: 14,
                weight: FontWeight.w600,
                color: dialogContext.scheme.onSurface,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(card.displayTitle, style: dialogContext.text.bodyMedium),
            const SizedBox(height: Spacing.md),
            Text(move.destinationSentence, style: dialogContext.text.bodyMedium),
            const SizedBox(height: Spacing.sm),
            Text(
              'Stage history is append-only, so this cannot be undone — only followed by another '
              'stage.',
              style: dialogContext.text.bodySmall
                  ?.copyWith(color: dialogContext.scheme.onSurfaceVariant),
            ),
            if (gate != null) ...[
              const SizedBox(height: Spacing.sm),
              Text(
                gate,
                style: dialogContext.text.bodySmall
                    ?.copyWith(color: dialogContext.dh.goldText),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text('Leave it at ${move.from.label}'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('Complete ${move.from.label}'),
        ),
      ],
    ),
  );
  return answer ?? false;
}

// ================================================================= commit

/// Permission, confirm, commit, report. The only way a stage moves from this feature.
Future<void> completeCardStage(
  BuildContext context,
  WidgetRef ref,
  BoardCard card,
) async {
  final move = StageTransition.after(card.columnStage);
  if (move == null) {
    showBoardMessage(
      context,
      '${card.columnStage.label} is the last stage on the rail. Nothing follows it.',
      isError: true,
    );
    return;
  }

  // Presentation only — RLS is the enforcement (D-008). What it buys is a reason instead of a
  // server refusal the operator cannot interpret.
  final blocked = ref.read(permissionsProvider).blockReason(move.capability);
  if (blocked != null) {
    showBoardMessage(context, blocked, isError: true);
    return;
  }

  if (ref.read(boardMovesProvider).containsKey(card.jobId)) {
    showBoardMessage(context, '${card.displayCode} is already moving. Give it a moment.');
    return;
  }

  final confirmed = await confirmStageMove(context, card: card, move: move);
  if (!confirmed || !context.mounted) return;

  try {
    await ref.read(boardMovesProvider.notifier).complete(card);
    if (!context.mounted) return;
    showBoardMessage(
      context,
      '${card.displayCode} completed ${move.from.label} and is now at ${move.to.label}.',
    );
  } on Object catch (error) {
    if (!context.mounted) return;
    showBoardFailure(context, error);
  }
}

/// A drop on [onto]. Refuses with the rail rule, or hands off to [completeCardStage].
Future<void> dropCardOnColumn(
  BuildContext context,
  WidgetRef ref, {
  required BoardCard card,
  required LifecycleStage onto,
}) async {
  if (onto == card.columnStage) return;
  final refusal = dropRefusal(from: card.columnStage, onto: onto);
  if (refusal != null) {
    showBoardMessage(context, refusal, isError: true);
    return;
  }
  await completeCardStage(context, ref, card);
}
