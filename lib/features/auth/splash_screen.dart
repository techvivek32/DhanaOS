/// The first frame: resolve Supabase, resolve the session, then hand over.
///
/// Four of the six states this screen can land in are ones the mockups never drew. Out of 46
/// exports there was one empty state and no error states at all — every screen arrived
/// pre-populated. A released APK built without `--dart-define` has to say so in words an
/// operator can act on, not crash on a null key at the first query.
///
/// Hand-off contract: pass [onResolved] and it fires once the gate settles on a destination
/// ([AuthGate.signedOut] or [AuthGate.ready]) — that is what the router's redirect binds to.
/// Leave it null and this screen is self-sufficient: it shows [LoginScreen] when signed out and
/// a session summary when signed in, so the app is runnable before the router lands.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/config.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/features/auth/login_screen.dart';
import 'package:dhanaos/features/auth/password_form.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

final class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key, this.onResolved});

  /// Called once, after the frame, when the gate reaches a destination. Router-owned
  /// navigation goes here; leave it null to let this screen render the destination itself.
  final void Function(AuthGate gate)? onResolved;

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  bool _handedOver = false;

  void _maybeHandOver(AuthGate gate) {
    final callback = widget.onResolved;
    if (callback == null || _handedOver) return;
    if (gate != AuthGate.ready && gate != AuthGate.signedOut) return;
    _handedOver = true;
    // The gate can settle during build; navigating from inside one is not allowed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback(gate);
    });
  }

  @override
  Widget build(BuildContext context) {
    final gate = ref.watch(authGateProvider);
    _maybeHandOver(gate);

    return Scaffold(
      body: SafeArea(
        child: switch (gate) {
          AuthGate.booting => const _Booting(),
          AuthGate.unconfigured => const _Unconfigured(),
          AuthGate.bootFailed => _BootFailed(
              onRetry: () => ref.invalidate(bootstrapProvider),
            ),
          AuthGate.profileBlocked => _ProfileBlocked(
              onRetry: () => ref.invalidate(currentUserProvider),
            ),
          AuthGate.unprovisioned => const _Unprovisioned(),
          AuthGate.suspended => const _Suspended(),
          AuthGate.deactivated => const _Deactivated(),
          AuthGate.mustChangePassword => const _SetPassword(),
          AuthGate.signedOut =>
            widget.onResolved == null ? const LoginScreen() : const _Booting(),
          AuthGate.ready =>
            widget.onResolved == null ? const SessionSummary() : const _Booting(),
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- states

final class _Booting extends StatelessWidget {
  const _Booting();

  @override
  Widget build(BuildContext context) {
    final dh = context.dh;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: dh.gold, borderRadius: Radii.rLg),
            child: Icon(Icons.diamond_outlined, size: 32, color: dh.onGold),
          ),
          const SizedBox(height: Spacing.lg),
          Text('DhanaOS', style: context.text.headlineMedium),
          const SizedBox(height: Spacing.lg),
          SizedBox(
            width: 120,
            child: LinearProgressIndicator(
              borderRadius: Radii.rFull,
              backgroundColor: dh.surfaceContainerHigh,
            ),
          ),
        ],
      ),
    );
  }
}

final class _Unconfigured extends StatelessWidget {
  const _Unconfigured();

  @override
  Widget build(BuildContext context) => ErrorState(
        icon: Icons.vpn_key_outlined,
        title: 'This build has no Supabase keys',
        message: Config.missingConfigMessage,
        detail: 'flutter run --dart-define-from-file=env/dev.json\n'
            'flutter build apk --release --dart-define-from-file=env/prod.json\n\n'
            'Keys never enter the repo — env/*.json is gitignored. The anon key is safe in an '
            'APK because every table is behind RLS (supabase/migrations/0009_rls.sql).',
      );
}

final class _BootFailed extends StatelessWidget {
  const _BootFailed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Consumer(
        builder: (context, ref, _) {
          // The wording came from `toDhFailure`, which already writes from the operator's side.
          final result = ref.watch(bootstrapProvider).value;
          final failure = result is BootstrapFailed ? result.failure : null;
          return ErrorState(
            icon: Icons.cloud_off_outlined,
            title: 'Could not reach the server',
            message: failure?.message ??
                'Supabase did not start. Check the connection and try again.',
            detail: failure?.detail,
            onRetry: onRetry,
            retryLabel: 'Try again',
          );
        },
      );
}

final class _ProfileBlocked extends StatelessWidget {
  const _ProfileBlocked({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Consumer(
        builder: (context, ref, _) {
          final error = ref.watch(currentUserProvider).error;
          return ErrorState(
            icon: Icons.person_off_outlined,
            title: 'Could not load your profile',
            message: 'You are signed in, but your account details did not load. '
                'Check the connection and try again.',
            detail: error?.toString(),
            onRetry: onRetry,
            retryLabel: 'Try again',
            secondaryLabel: 'Sign out',
            onSecondary: () => ref.read(authControllerProvider.notifier).signOut(),
          );
        },
      );
}

final class _Unprovisioned extends StatelessWidget {
  const _Unprovisioned();

  @override
  Widget build(BuildContext context) => Consumer(
        builder: (context, ref, _) => EmptyState(
          icon: Icons.badge_outlined,
          title: 'This account is not set up yet',
          message: 'Your sign-in works, but nobody has added you to a workshop. '
              'Ask an admin to create your user and give it a role.',
          actionLabel: 'Sign out',
          onAction: () => ref.read(authControllerProvider.notifier).signOut(),
        ),
      );
}

/// 0014: the platform paused the whole workspace. RLS already returns nothing, so this says why
/// rather than letting every screen come back empty.
final class _Suspended extends ConsumerWidget {
  const _Suspended();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    final workspace = user?.orgName ?? 'This workspace';
    final reason = user?.orgSuspendedReason;
    return EmptyState(
      icon: Icons.pause_circle_outline,
      title: '$workspace is suspended',
      message: '${reason == null ? '' : 'Reason: $reason. '}'
          'Nothing in the workspace can be opened until DhanaOS reactivates it. '
          'Your workshop owner can contact DhanaOS support.',
      actionLabel: 'Sign out',
      onAction: () => ref.read(authControllerProvider.notifier).signOut(),
    );
  }
}

final class _Deactivated extends ConsumerWidget {
  const _Deactivated();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(currentUserProvider).value?.orgName ?? 'your workshop';
    return EmptyState(
      icon: Icons.person_off_outlined,
      title: 'This account is turned off',
      message: 'An administrator of $workspace deactivated it. Everything you recorded stays '
          'on the jobs; ask them to reactivate the account if you still need it.',
      actionLabel: 'Sign out',
      onAction: () => ref.read(authControllerProvider.notifier).signOut(),
    );
  }
}

/// 0014: the account was created, or its password reset, with a temporary password. Nothing
/// else opens until it is replaced — the admin who typed it has seen it.
final class _SetPassword extends ConsumerWidget {
  const _SetPassword();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final user = ref.watch(currentUserProvider).value;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.lg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.lock_reset_outlined, size: 40, color: context.dh.gold),
              const SizedBox(height: Spacing.md),
              Text(
                'Set your own password',
                textAlign: TextAlign.center,
                style: context.text.headlineMedium?.copyWith(color: scheme.onSurface),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                '${user == null ? 'You' : '${user.fullName}, you'} signed in with a temporary '
                'password from your administrator. Choose your own to continue.',
                textAlign: TextAlign.center,
                style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: Spacing.lg),
              const NewPasswordForm(submitLabel: 'Save and continue'),
              const SizedBox(height: Spacing.sm),
              TextButton(
                onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- signed in

/// What a resolved session looks like before the router and dashboard exist.
///
/// D-008's test in one widget: every value on this card came from the session user's own
/// `app_users` row. There is no literal name anywhere in this file — which is precisely what
/// all 46 mockups got wrong when they pasted "Ravi S. — Manufacturing Engineer" onto the vendor
/// and customer screens.
final class SessionSummary extends ConsumerWidget {
  const SessionSummary({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    final scheme = context.scheme;
    final dh = context.dh;

    if (user == null) return const _Booting();

    final roles = user.roles.toList()..sort((a, b) => a.index.compareTo(b.index));

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.lg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: DhSectionCard(
            title: 'Signed in',
            subtitle: 'The dashboard lands here once the router is wired.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: dh.surfaceContainerHigh,
                        borderRadius: Radii.rFull,
                      ),
                      child: Text(
                        user.displayInitials,
                        style: AppTheme.mono(size: 14, color: scheme.onSurface),
                      ),
                    ),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(user.fullName, style: context.text.titleMedium),
                          Text(
                            user.subtitle,
                            style: context.text.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.md),
                DataPair(
                  label: 'Principal',
                  value: user.principal.wire,
                ),
                DataPair(
                  label: 'Roles',
                  value: roles.isEmpty
                      ? 'None assigned'
                      : [for (final role in roles) role.label].join(' · '),
                ),
                DataPair(label: 'Org', value: user.orgId, mono: true),
                const SizedBox(height: Spacing.md),
                OutlinedButton(
                  onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
