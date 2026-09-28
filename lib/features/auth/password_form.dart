/// A new password, typed twice.
///
/// Used where an admin-issued temporary password has to be replaced at first sign-in (0014), and
/// from My account. The rules shown are the ones the server enforces — eight characters — so the
/// form never accepts something gotrue will refuse.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/features/auth/auth_banner.dart';
import 'package:dhanaos/features/auth/session.dart';

const minPasswordLength = 8;

final class NewPasswordForm extends ConsumerStatefulWidget {
  const NewPasswordForm({super.key, this.submitLabel = 'Save new password', this.onChanged});

  final String submitLabel;

  /// Called after the server accepted the new password.
  final VoidCallback? onChanged;

  @override
  ConsumerState<NewPasswordForm> createState() => _NewPasswordFormState();
}

class _NewPasswordFormState extends ConsumerState<NewPasswordForm> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final ok = await ref.read(authControllerProvider.notifier).changePassword(_password.text);
    if (!ok || !mounted) return;
    _password.clear();
    _confirm.clear();
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final busy = state.isLoading;
    final error = state.error;
    final failure = busy || error is! DhFailure ? null : error;

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (failure != null) ...[
            AuthBanner(message: failure.message, tone: AuthBannerTone.error),
            const SizedBox(height: Spacing.md),
          ],
          TextFormField(
            controller: _password,
            enabled: !busy,
            obscureText: _obscure,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.newPassword],
            decoration: InputDecoration(
              labelText: 'New password',
              helperText: 'At least $minPasswordLength characters.',
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                tooltip: _obscure ? 'Show password' : 'Hide password',
              ),
            ),
            validator: (value) => (value ?? '').length < minPasswordLength
                ? 'Use at least $minPasswordLength characters.'
                : null,
          ),
          const SizedBox(height: Spacing.md),
          TextFormField(
            controller: _confirm,
            enabled: !busy,
            obscureText: _obscure,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.newPassword],
            onFieldSubmitted: (_) => _submit(),
            decoration: const InputDecoration(labelText: 'Type it again'),
            validator: (value) =>
                value == _password.text ? null : 'The two passwords do not match.',
          ),
          const SizedBox(height: Spacing.lg),
          FilledButton(
            onPressed: busy ? null : _submit,
            child: busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(widget.submitLabel),
          ),
        ],
      ),
    );
  }
}
