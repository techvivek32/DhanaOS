/// The global chrome: search, notifications, identity.
///
/// Three things the mockups drew and never wired are made real here.
///
///  * The search field carried the placeholder "Job ID, Customer, or Specialist" on every
///    screen with **nothing behind it**. Submitting now lands on the job list with `?q=`, which
///    is the one query the whole app agrees on.
///  * The notification bell had a hardcoded badge. It now counts open `action_items` for this
///    org and opens them, with each item's own `cta_route` as its destination.
///  * The user chip showed "Ravi S. — Manufacturing Engineer" in all 46 exports, including the
///    external vendor's dashboard and the customer's approval screen. D-008 forbids that
///    outright: this renders the session user or nothing at all.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/app_user.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/shared/shell/app_shell.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

part 'top_bar.g.dart';

/// One row of `action_items` — the shell needs four columns of it and no more, so it does not
/// wait on a repository to read them.
@immutable
final class OpenAction {
  const OpenAction({
    required this.id,
    required this.label,
    required this.severity,
    this.ctaLabel,
    this.ctaRoute,
  });

  factory OpenAction.fromRow(Map<String, dynamic> row) => OpenAction(
        id: row['id'] as String,
        label: row['label'] as String,
        // Convention 6: the wire value, never `.name`.
        severity: ActionSeverity.parse(row['severity'] as String?) ?? ActionSeverity.info,
        ctaLabel: row['cta_label'] as String?,
        ctaRoute: row['cta_route'] as String?,
      );

  final String id;
  final String label;
  final ActionSeverity severity;
  final String? ctaLabel;

  /// An in-app path written by whoever raised the item. Only absolute paths are followed, so a
  /// malformed row cannot send an operator somewhere strange.
  final String? ctaRoute;

  bool get hasRoute => ctaRoute != null && ctaRoute!.startsWith('/');
}

/// Open action items for the signed-in operator.
///
/// `action_items` is internal-only in RLS (`actions_internal`), so this returns nothing for a
/// partner or customer principal rather than failing — which is why the bell is not rendered
/// for them at all.
@riverpod
Future<List<OpenAction>> openActions(Ref ref) async {
  final user = await ref.watch(currentUserProvider.future);
  if (user == null || !user.isInternal) return const <OpenAction>[];

  // Safe to read here and not before: awaiting the profile means bootstrap has already
  // resolved, which is the precondition `supabaseProvider` documents.
  final client = ref.watch(supabaseProvider);
  final rows = await guard<List<Map<String, dynamic>>>(
    () async => client
        .from('action_items')
        .select('id, label, severity, cta_label, cta_route')
        .isFilter('resolved_at', null)
        .order('created_at', ascending: false)
        // A bell is a nudge, not an inbox. Ninety-nine is already "too many".
        .limit(99),
  );
  return rows.map(OpenAction.fromRow).toList(growable: false);
}

final class TopBar extends ConsumerWidget {
  const TopBar({super.key, required this.wide, required this.area});

  final bool wide;

  /// The branch the operator is standing in, used as the narrow-layout title.
  final NavArea area;

  static const height = 64.0;

  /// The mockups' placeholder, kept word for word — and now attached to something.
  static const searchHint = 'Job ID, Customer, or Specialist';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).valueOrNull;
    // D-008. Global search resolves to the internal job list, so offering it to a vendor or a
    // retailer would be offering a door the redirect closes again.
    final internal = user?.isInternal ?? false;

    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm + Spacing.xs),
        child: Row(
          children: [
            if (context.canPop())
              IconButton(
                onPressed: () => context.pop(),
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Back',
              ),
            if (internal && wide)
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: const _SearchField(),
                  ),
                ),
              )
            else
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: Spacing.xs),
                  child: Text(
                    area.label,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.headlineSmall,
                  ),
                ),
              ),
            if (internal && !wide)
              IconButton(
                onPressed: () => unawaited(_openSearchSheet(context)),
                icon: const Icon(Icons.search_rounded),
                tooltip: 'Search jobs',
              ),
            if (internal) const _NotificationBell(),
            const SizedBox(width: Spacing.xs),
            _UserChip(user: user, wide: wide),
          ],
        ),
      ),
    );
  }
}

final class _SearchField extends StatefulWidget {
  const _SearchField();

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final query = raw.trim();
    if (query.isEmpty) return;
    context.go(Paths.jobSearch(query));
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      textInputAction: TextInputAction.search,
      onSubmitted: _submit,
      style: context.text.bodyMedium,
      decoration: const InputDecoration(
        hintText: TopBar.searchHint,
        isDense: true,
        prefixIcon: Icon(Icons.search_rounded, size: 20),
        contentPadding: EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm + Spacing.xs,
        ),
      ),
    );
  }
}

/// The phone equivalent of the field: a sheet, rather than a field squeezed into 360px beside
/// three other controls.
Future<void> _openSearchSheet(BuildContext context) async {
  final query = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _SearchSheet(),
  );
  if (!context.mounted) return;
  final trimmed = query?.trim() ?? '';
  if (trimmed.isEmpty) return;
  context.go(Paths.jobSearch(trimmed));
}

/// Owns its own controller so it lives exactly as long as the field does — disposing one from
/// the caller kills it while the sheet is still animating out.
final class _SearchSheet extends StatefulWidget {
  const _SearchSheet();

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: Spacing.md,
        right: Spacing.md,
        top: Spacing.md,
        bottom: MediaQuery.viewInsetsOf(context).bottom + Spacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Find a job', style: context.text.headlineSmall),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              hintText: TopBar.searchHint,
              prefixIcon: Icon(Icons.search_rounded, size: 20),
            ),
          ),
          const SizedBox(height: Spacing.md),
          FilledButton(onPressed: _submit, child: const Text('Search')),
        ],
      ),
    );
  }
}

final class _NotificationBell extends ConsumerWidget {
  const _NotificationBell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.watch(openActionsProvider).valueOrNull ?? const <OpenAction>[];
    final count = actions.length;

    return IconButton(
      onPressed: () => unawaited(_openActionsSheet(context, ref, actions)),
      tooltip: count == 0 ? 'No open items' : '$count open item${count == 1 ? '' : 's'}',
      icon: Badge(
        isLabelVisible: count > 0,
        // Ninety-nine is the query cap; past that the exact number stops being actionable.
        label: Text(count > 9 ? '9+' : '$count'),
        backgroundColor: context.scheme.error,
        textColor: context.scheme.onError,
        child: const Icon(Icons.notifications_none_rounded),
      ),
    );
  }
}

Future<void> _openActionsSheet(
  BuildContext context,
  WidgetRef ref,
  List<OpenAction> actions,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
        ),
        child: actions.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(Spacing.lg),
                child: EmptyState(
                  compact: true,
                  icon: Icons.notifications_none_rounded,
                  title: 'Nothing waiting on you',
                  message: 'Exceptions, delayed stages and approvals land here as they are '
                      'raised.',
                ),
              )
            : ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(
                  Spacing.md,
                  0,
                  Spacing.md,
                  Spacing.md,
                ),
                itemCount: actions.length,
                separatorBuilder: (_, __) => const SizedBox(height: Spacing.sm),
                itemBuilder: (itemContext, i) {
                  final item = actions[i];
                  return DhCard(
                    onTap: item.hasRoute
                        ? () {
                            Navigator.of(sheetContext).pop();
                            context.go(item.ctaRoute!);
                          }
                        : null,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SeverityChip(item.severity, dense: true),
                              const SizedBox(height: Spacing.sm),
                              Text(item.label, style: itemContext.text.bodyLarge),
                            ],
                          ),
                        ),
                        if (item.hasRoute) ...[
                          const SizedBox(width: Spacing.sm),
                          Text(
                            item.ctaLabel ?? 'Open',
                            style: itemContext.text.labelMedium
                                ?.copyWith(color: itemContext.scheme.secondary),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
      ),
    ),
  ).whenComplete(() {
    // The sheet can outlive a navigation, and invalidating through a disposed WidgetRef throws.
    if (context.mounted) ref.invalidate(openActionsProvider);
  });
}

/// D-008's visible half: the one place the app states who it thinks you are.
final class _UserChip extends ConsumerWidget {
  const _UserChip({required this.user, required this.wide});

  final AppUser? user;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final current = user;
    if (current == null) {
      return TextButton(
        onPressed: () => context.go(Paths.login),
        child: const Text('Sign in'),
      );
    }

    final narrowExtras = !wide && current.isInternal;

    // Watched rather than read, for two reasons. It closes the menu to a second tap while a
    // sign-out is already in flight, and — because [AuthController] is auto-disposed — it is
    // what keeps the notifier alive across the await in [_onMenu]. A notifier disposed
    // mid-sign-out throws when it writes its own result back.
    final busy = ref.watch(authControllerProvider).isLoading;

    return PopupMenuButton<String>(
      tooltip: 'Account',
      enabled: !busy,
      position: PopupMenuPosition.under,
      onSelected: (value) => unawaited(_onMenu(context, ref, value)),
      itemBuilder: (menuContext) => [
        PopupMenuItem<String>(
          enabled: false,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(current.fullName),
            subtitle: Text(current.subtitle),
          ),
        ),
        const PopupMenuDivider(),
        if (narrowExtras)
          const PopupMenuItem<String>(
            value: 'partners',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.handshake_outlined),
              title: Text('Partners'),
            ),
          ),
        if (current.isInternal)
          const PopupMenuItem<String>(
            value: 'settings',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.settings_outlined),
              title: Text('Settings'),
            ),
          ),
        const PopupMenuItem<String>(
          value: 'signout',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout_rounded),
            title: Text('Sign out'),
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: Spacing.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: Spacing.rowHeightSm,
              height: Spacing.rowHeightSm,
              decoration: BoxDecoration(
                color: context.dh.surfaceContainerHigh,
                borderRadius: Radii.rFull,
                border: Border.all(color: context.dh.outlineVariant),
              ),
              alignment: Alignment.center,
              child: Text(
                current.displayInitials,
                style: AppTheme.mono(size: 11, weight: FontWeight.w600, color: scheme.onSurface),
              ),
            ),
            if (wide) ...[
              const SizedBox(width: Spacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      current.fullName,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      current.subtitle,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Icon(Icons.expand_more_rounded, size: 18, color: scheme.onSurfaceVariant),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _onMenu(BuildContext context, WidgetRef ref, String value) async {
    switch (value) {
      case 'partners':
        context.go(Paths.partner);
      case 'settings':
        context.go(Paths.settings);
      case 'signout':
        // Through the controller, not the raw client: D-008 requires the realtime channels to
        // go with the session. A partner's job channels are subscribed under that partner's
        // JWT, and leaving them open on a shared shop-floor tablet would keep pushing one
        // vendor's rows into the next vendor's session. The auth stream then drives the gate,
        // which drives the redirect — nothing here needs to navigate.
        await ref.read(authControllerProvider.notifier).signOut();
    }
  }
}
