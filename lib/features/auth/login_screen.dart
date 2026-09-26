/// Sign in — email and password, or a code to a phone.
///
/// Two paths because the shop has two kinds of operator. The office signs in with an email and
/// a password. The bench, the caster and the courier desk have a phone and often no company
/// mailbox at all, so D-007 put phone OTP in the stack from the start.
///
/// The screen never decides anything about identity. It hands credentials to
/// [AuthController]; when the session lands, [authGateProvider] flips and whatever is showing
/// this screen replaces it. That is deliberate — a login screen that navigates on success is a
/// login screen that can navigate on a session that did not actually establish.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

enum _Method { password, phone }

final class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();

  _Method _method = _Method.password;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final controller = ref.read(authControllerProvider.notifier);
    final form = ref.read(authControllerProvider).valueOrNull;

    switch (_method) {
      case _Method.password:
        await controller.signInWithPassword(
          email: _email.text,
          password: _password.text,
        );
      case _Method.phone:
        if (form?.awaitingCode ?? false) {
          await controller.verifyPhoneCode(_code.text);
        } else {
          await controller.sendPhoneCode(_phone.text);
        }
    }
  }

  Future<void> _resetPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      // Nothing to send to. Point at the field rather than firing a request that will fail.
      _formKey.currentState?.validate();
      return;
    }
    await ref.read(authControllerProvider.notifier).sendPasswordReset(email);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final form = state.valueOrNull;
    final busy = state.isLoading;
    // The previous error rides along through a retry (so the phone step is not lost), but a
    // stale refusal under a spinner reads as a fresh one — hide it while the request is out.
    final error = state.error;
    final failure = busy || error is! DhFailure ? null : error;
    final awaitingCode = _method == _Method.phone && (form?.awaitingCode ?? false);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _BrandMark(),
                      const SizedBox(height: Spacing.xl),
                      DhSegmented<_Method>(
                        value: _method,
                        segments: const [
                          DhSegment(
                            value: _Method.password,
                            label: 'Password',
                            icon: Icons.mail_outline,
                          ),
                          DhSegment(
                            value: _Method.phone,
                            label: 'Phone code',
                            icon: Icons.sms_outlined,
                          ),
                        ],
                        onChanged: busy
                            ? (_) {}
                            : (value) => setState(() => _method = value),
                      ),
                      const SizedBox(height: Spacing.lg),
                      if (form?.notice != null) ...[
                        _Banner(message: form!.notice!, tone: _BannerTone.info),
                        const SizedBox(height: Spacing.md),
                      ],
                      if (failure != null) ...[
                        _Banner(
                          message: failure.message,
                          tone: _BannerTone.error,
                        ),
                        const SizedBox(height: Spacing.md),
                      ],
                      switch (_method) {
                        _Method.password => _PasswordFields(
                            email: _email,
                            password: _password,
                            obscure: _obscure,
                            enabled: !busy,
                            onToggleObscure: () => setState(() => _obscure = !_obscure),
                            onSubmit: _submit,
                          ),
                        _Method.phone => _PhoneFields(
                            phone: _phone,
                            code: _code,
                            awaitingCode: awaitingCode,
                            enabled: !busy,
                            onSubmit: _submit,
                          ),
                      },
                      const SizedBox(height: Spacing.lg),
                      FilledButton(
                        onPressed: busy ? null : _submit,
                        child: busy
                            ? const _ButtonSpinner()
                            : Text(_primaryLabel(awaitingCode: awaitingCode)),
                      ),
                      const SizedBox(height: Spacing.sm),
                      _SecondaryAction(
                        method: _method,
                        awaitingCode: awaitingCode,
                        canResend: form?.canResend ?? true,
                        enabled: !busy,
                        onResetPassword: _resetPassword,
                        onChangeNumber: () {
                          _code.clear();
                          ref.read(authControllerProvider.notifier).clearPhoneCode();
                        },
                        onResend: () => ref
                            .read(authControllerProvider.notifier)
                            .sendPhoneCode(_phone.text),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _primaryLabel({required bool awaitingCode}) => switch (_method) {
        _Method.password => 'Sign in',
        _Method.phone => awaitingCode ? 'Verify and sign in' : 'Send code',
      };
}

// ---------------------------------------------------------------- pieces

final class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: dh.gold,
            borderRadius: Radii.rLg,
          ),
          child: Icon(Icons.diamond_outlined, size: 32, color: dh.onGold),
        ),
        const SizedBox(height: Spacing.md),
        Text(
          'DhanaOS',
          textAlign: TextAlign.center,
          style: context.text.headlineLarge?.copyWith(color: scheme.onSurface),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          'Manufacturing operations for the workshop floor',
          textAlign: TextAlign.center,
          style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

final class _PasswordFields extends StatelessWidget {
  const _PasswordFields({
    required this.email,
    required this.password,
    required this.obscure,
    required this.enabled,
    required this.onToggleObscure,
    required this.onSubmit,
  });

  final TextEditingController email;
  final TextEditingController password;
  final bool obscure;
  final bool enabled;
  final VoidCallback onToggleObscure;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: email,
          enabled: enabled,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          autofillHints: const [AutofillHints.username, AutofillHints.email],
          decoration: const InputDecoration(
            labelText: 'Work email',
            hintText: 'you@auraforge.in',
          ),
          validator: (value) {
            final text = value?.trim() ?? '';
            if (text.isEmpty) return 'Enter the email your account was created with.';
            if (!text.contains('@') || !text.contains('.')) {
              return 'That does not look like an email address.';
            }
            return null;
          },
        ),
        const SizedBox(height: Spacing.md),
        TextFormField(
          controller: password,
          enabled: enabled,
          obscureText: obscure,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.password],
          onFieldSubmitted: (_) => onSubmit(),
          decoration: InputDecoration(
            labelText: 'Password',
            suffixIcon: IconButton(
              onPressed: onToggleObscure,
              icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              tooltip: obscure ? 'Show password' : 'Hide password',
            ),
          ),
          validator: (value) =>
              (value ?? '').isEmpty ? 'Enter your password.' : null,
        ),
      ],
    );
  }
}

final class _PhoneFields extends StatelessWidget {
  const _PhoneFields({
    required this.phone,
    required this.code,
    required this.awaitingCode,
    required this.enabled,
    required this.onSubmit,
  });

  final TextEditingController phone;
  final TextEditingController code;
  final bool awaitingCode;
  final bool enabled;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: phone,
          enabled: enabled && !awaitingCode,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.telephoneNumber],
          // Convention 5: a phone number is data. Mono keeps digits comparable.
          style: AppTheme.mono(size: 15, color: scheme.onSurface),
          decoration: const InputDecoration(
            labelText: 'Mobile number',
            hintText: '98765 43210',
            helperText: 'Ten digits for India, or the full number with its country code.',
          ),
          validator: (value) {
            if (awaitingCode) return null;
            final normalised = normalisePhone(value ?? '');
            if (normalised.length < 11) {
              return 'Enter the full mobile number, including the country code if it is not Indian.';
            }
            return null;
          },
        ),
        if (awaitingCode) ...[
          const SizedBox(height: Spacing.md),
          TextFormField(
            controller: code,
            enabled: enabled,
            autofocus: true,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            maxLength: 6,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: AppTheme.mono(size: 22, color: scheme.onSurface),
            onFieldSubmitted: (_) => onSubmit(),
            decoration: const InputDecoration(
              labelText: 'Six-digit code',
              counterText: '',
            ),
            validator: (value) => (value ?? '').length == 6
                ? null
                : 'Enter all six digits from the message.',
          ),
        ],
      ],
    );
  }
}

final class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({
    required this.method,
    required this.awaitingCode,
    required this.canResend,
    required this.enabled,
    required this.onResetPassword,
    required this.onChangeNumber,
    required this.onResend,
  });

  final _Method method;
  final bool awaitingCode;
  final bool canResend;
  final bool enabled;
  final Future<void> Function() onResetPassword;
  final VoidCallback onChangeNumber;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) {
    if (method == _Method.password) {
      return TextButton(
        onPressed: enabled ? onResetPassword : null,
        child: const Text('Email me a password reset link'),
      );
    }
    if (!awaitingCode) {
      return Text(
        'We text a one-time code. Your number has to already be on your account — '
        'this does not create one.',
        textAlign: TextAlign.center,
        style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        TextButton(
          onPressed: enabled ? onChangeNumber : null,
          child: const Text('Use a different number'),
        ),
        TextButton(
          onPressed: enabled && canResend ? onResend : null,
          child: Text(canResend ? 'Resend code' : 'Resend in a minute'),
        ),
      ],
    );
  }
}

enum _BannerTone { info, error }

final class _Banner extends StatelessWidget {
  const _Banner({required this.message, required this.tone});

  final String message;
  final _BannerTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final (background, foreground, icon) = switch (tone) {
      _BannerTone.error => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          Icons.error_outline,
        ),
      _BannerTone.info => (
          dh.successContainer,
          dh.success,
          Icons.mark_email_read_outlined,
        ),
    };

    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(color: background, borderRadius: Radii.rMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              // Server messages reach the operator in the server's words. gotrue and the D-011
              // rules both write from the operator's side already; paraphrasing lets the two
              // drift apart.
              message,
              style: context.text.bodyMedium?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

final class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: context.scheme.onPrimary,
        ),
      );
}
