/// The message strip above an auth form: a server refusal in the server's own words, or a
/// confirmation. Shared by sign-in, first-sign-in password change and My account.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';

enum AuthBannerTone { info, error }

final class AuthBanner extends StatelessWidget {
  const AuthBanner({super.key, required this.message, required this.tone});

  final String message;
  final AuthBannerTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final (background, foreground, icon) = switch (tone) {
      AuthBannerTone.error => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          Icons.error_outline,
        ),
      AuthBannerTone.info => (
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
