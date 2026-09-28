/// Sign-in, and every state that is not a console — each one explained in words an
/// administrator can act on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/admin/admin_identity.dart';
import 'package:dhanaos/admin/theme_mode.dart';
import 'package:dhanaos/core/config.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/features/auth/auth_banner.dart';
import 'package:dhanaos/features/auth/password_form.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/shared/widgets/dh_card.dart';
import 'package:dhanaos/shared/widgets/empty_state.dart';

/// A centred card on the app surface — the frame every gate state and sign-in shares.
final class _GateFrame extends StatelessWidget {
  const _GateFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.lg),
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: child),
          ),
        ),
        const Positioned(
          top: Spacing.md,
          right: Spacing.md,
          child: SizedBox(width: 240, child: ThemeModeSwitch()),
        ),
      ],
    ),
  );
}

final class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final dh = context.dh;
    final scheme = context.scheme;
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(color: dh.gold, borderRadius: Radii.rLg),
          child: Icon(Icons.diamond_outlined, size: 32, color: dh.onGold),
        ),
        const SizedBox(height: Spacing.md),
        Text('DhanaOS Admin', style: context.text.headlineLarge?.copyWith(color: scheme.onSurface)),
        const SizedBox(height: Spacing.xs),
        Text(
          'Workspaces, people and settings',
          style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

// ================================================================= sign in

final class AdminLoginPage extends ConsumerStatefulWidget {
  const AdminLoginPage({super.key});

  @override
  ConsumerState<AdminLoginPage> createState() => _AdminLoginPageState();
}

class _AdminLoginPageState extends ConsumerState<AdminLoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await ref
        .read(authControllerProvider.notifier)
        .signInWithPassword(email: _email.text, password: _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final busy = state.isLoading;
    final error = state.error;
    final failure = busy || error is! DhFailure ? null : error;

    return _GateFrame(
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Brand(),
              const SizedBox(height: Spacing.xl),
              if (failure != null) ...[
                AuthBanner(message: failure.message, tone: AuthBannerTone.error),
                const SizedBox(height: Spacing.md),
              ],
              TextFormField(
                controller: _email,
                enabled: !busy,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.username, AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) => (v ?? '').trim().contains('@') ? null : 'Enter your email.',
              ),
              const SizedBox(height: Spacing.md),
              TextFormField(
                controller: _password,
                enabled: !busy,
                obscureText: _obscure,
                autofillHints: const [AutofillHints.password],
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    ),
                    tooltip: _obscure ? 'Show password' : 'Hide password',
                  ),
                ),
                validator: (v) => (v ?? '').isEmpty ? 'Enter your password.' : null,
              ),
              const SizedBox(height: Spacing.lg),
              FilledButton(
                onPressed: busy ? null : _submit,
                child: busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================================================================= gate

final class GatePage extends ConsumerWidget {
  const GatePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gate = ref.watch(adminGateProvider);
    void signOut() => ref.read(authControllerProvider.notifier).signOut();

    return switch (gate) {
      AdminGate.unconfigured => _GateFrame(
        child: ErrorState(
          icon: Icons.vpn_key_outlined,
          title: 'This build has no Supabase keys',
          message: Config.missingConfigMessage,
        ),
      ),
      AdminGate.bootFailed => _GateFrame(
        child: ErrorState(
          icon: Icons.cloud_off_outlined,
          title: 'Could not reach the server',
          message: 'Check the connection and try again.',
          onRetry: () => ref.invalidate(bootstrapProvider),
        ),
      ),
      AdminGate.failed => _GateFrame(
        child: ErrorState(
          icon: Icons.person_off_outlined,
          title: 'Could not load your account',
          message: 'You are signed in, but your account did not load.',
          onRetry: () => ref.invalidate(adminIdentityProvider),
          secondaryLabel: 'Sign out',
          onSecondary: signOut,
        ),
      ),
      AdminGate.notAdmin => _GateFrame(
        child: EmptyState(
          icon: Icons.admin_panel_settings_outlined,
          title: 'This panel is for administrators',
          message:
              'Your account works, but it has no admin role. Use the DhanaOS app on your '
              'phone, or ask your workspace admin for access.',
          actionLabel: 'Sign out',
          onAction: signOut,
        ),
      ),
      AdminGate.suspended => _GateFrame(child: _Suspended(onSignOut: signOut)),
      AdminGate.deactivated => _GateFrame(
        child: EmptyState(
          icon: Icons.person_off_outlined,
          title: 'This account is turned off',
          message:
              'Another administrator of your workspace deactivated it. Ask them to '
              'reactivate it.',
          actionLabel: 'Sign out',
          onAction: signOut,
        ),
      ),
      AdminGate.mustChangePassword => _GateFrame(child: _SetPassword(onSignOut: signOut)),
      AdminGate.booting ||
      AdminGate.signedOut ||
      AdminGate.platform ||
      AdminGate.workspace => const _GateFrame(child: _Booting()),
    };
  }
}

final class _Booting extends StatelessWidget {
  const _Booting();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const _Brand(),
      const SizedBox(height: Spacing.lg),
      SizedBox(
        width: 140,
        child: LinearProgressIndicator(
          borderRadius: Radii.rFull,
          backgroundColor: context.dh.surfaceContainerHigh,
        ),
      ),
    ],
  );
}

final class _Suspended extends ConsumerWidget {
  const _Suspended({required this.onSignOut});

  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    final reason = user?.orgSuspendedReason;
    return EmptyState(
      icon: Icons.pause_circle_outline,
      title: '${user?.orgName ?? 'This workspace'} is suspended',
      message:
          '${reason == null ? '' : 'Reason: $reason. '}'
          'Contact DhanaOS support to reactivate it.',
      actionLabel: 'Sign out',
      onAction: onSignOut,
    );
  }
}

final class _SetPassword extends ConsumerWidget {
  const _SetPassword({required this.onSignOut});

  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final user = ref.watch(currentUserProvider).value;
    return DhCard(
      padding: const EdgeInsets.all(Spacing.lg),
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
            'password. Choose your own to open the admin panel.',
            textAlign: TextAlign.center,
            style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.lg),
          const NewPasswordForm(submitLabel: 'Save and continue'),
          const SizedBox(height: Spacing.sm),
          TextButton(onPressed: onSignOut, child: const Text('Sign out')),
        ],
      ),
    );
  }
}
