/// Who is signed in — and the rule that this is the only place the app may ask.
///
/// D-008 is the reason this file exists. All 46 mockups hardcoded one identity, "Ravi S. —
/// Manufacturing Engineer", and that literal leaked onto the external vendor's screen and onto
/// the customer's approval screen. A vendor reading another vendor's job is a business-ending
/// defect; a customer reading a name that is not theirs is close behind.
///
/// So: **no screen renders an identity that did not come from [currentUserProvider].** There is
/// no other source. There is no fallback literal. If the profile cannot be read, the gate says
/// so ([AuthGate.profileBlocked]) rather than drawing a plausible name.
///
/// Access itself is never decided here. RLS (0009_rls.sql) decides it. What lives here is
/// identity and the sign-in transitions.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'session.g.dart';

/// `app_users` plus the three joins that complete an identity: the roles it holds, and the
/// retailer or vendor it belongs to. `partner_id` is what actually scopes a vendor's queue —
/// the mockup used a decorative "Assigned to Me" chip with nothing behind it.
const _userSelect = '*, user_roles(role), customer_users(customer_id), partner_users(partner_id)';

// ---------------------------------------------------------------- session

/// Raw auth transitions. Emits `initialSession` as soon as it is listened to, which is what
/// makes a cold start resolve without a timer.
@Riverpod(keepAlive: true)
Stream<AuthState> authStateChanges(Ref ref) =>
    ref.watch(supabaseAuthProvider).onAuthStateChange;

/// The live Supabase session, or null when signed out.
@Riverpod(keepAlive: true)
Session? currentSession(Ref ref) {
  final changes = ref.watch(authStateChangesProvider);
  // Once the stream has spoken it is authoritative — including when it says "signed out".
  if (changes.hasValue) return changes.value?.session;
  // Before that, the client may already have rehydrated a persisted session from disk.
  return ref.watch(supabaseAuthProvider).currentSession;
}

// ---------------------------------------------------------------- profile

/// The signed-in operator's `app_users` row, with roles.
///
/// Null means the account authenticates but has not been provisioned into an org — a real
/// state, not an error: someone was invited in Supabase Auth and nobody added them to
/// `app_users`. [AuthGate.unprovisioned] is how that reaches the screen.
@Riverpod(keepAlive: true)
Future<AppUser?> currentUser(Ref ref) async {
  final session = ref.watch(currentSessionProvider);
  if (session == null) return null;

  final client = ref.watch(supabaseProvider);
  final row = await guardOrNull(
    () => client.from('app_users').select(_userSelect).eq('id', session.user.id).maybeSingle(),
  );
  if (row == null) return null;

  final user = AppUser.fromJson(_shapeUserRow(row));

  // D-008, belt and braces. RLS already restricts `app_users` to the caller and their org, but
  // an over-broad policy would let this provider hand a *different* person's name to every
  // screen in the app. Refuse rather than render.
  if (user.id != session.user.id) {
    throw PermissionDenied(
      message: 'This session does not match the profile the server returned. '
          'Sign out and sign in again.',
      detail: 'session=${session.user.id} profile=${user.id}',
      code: 'identity_mismatch',
    );
  }
  return user;
}

/// D-008's three principal classes. Null while signing in or when unprovisioned.
@Riverpod(keepAlive: true)
PrincipalClass? currentPrincipal(Ref ref) =>
    ref.watch(currentUserProvider).valueOrNull?.principal;

/// The org every write is scoped to. Convenience for repositories that need `org_id` on an
/// insert — they must never invent one.
@Riverpod(keepAlive: true)
String? currentOrgId(Ref ref) => ref.watch(currentUserProvider).valueOrNull?.orgId;

/// PostgREST returns embedded rows as nested objects. The model wants flat fields, and
/// `user_roles` in particular arrives as `[{role: admin}, {role: engineer}]` while
/// `AppUser.roleWires` wants `['admin', 'engineer']`.
///
/// `customer_users` and `partner_users` are one-to-one (their PK *is* the FK), so PostgREST may
/// send either a single object or a one-element list depending on how it resolved the
/// relationship. Both shapes are handled rather than guessed at.
Map<String, dynamic> _shapeUserRow(Map<String, dynamic> row) {
  final shaped = Map<String, dynamic>.from(row);

  final roles = <String>[];
  final embedded = row['user_roles'];
  if (embedded is List) {
    for (final entry in embedded) {
      if (entry is Map && entry['role'] is String) roles.add(entry['role'] as String);
    }
  }
  shaped
    ..remove('user_roles')
    ..['roles'] = roles
    ..['customer_id'] = _embeddedId(row['customer_users'], 'customer_id')
    ..['partner_id'] = _embeddedId(row['partner_users'], 'partner_id')
    ..remove('customer_users')
    ..remove('partner_users');

  return shaped;
}

String? _embeddedId(Object? embedded, String column) {
  if (embedded is Map) return embedded[column] as String?;
  if (embedded is List && embedded.isNotEmpty) {
    final first = embedded.first;
    if (first is Map) return first[column] as String?;
  }
  return null;
}

// ---------------------------------------------------------------- the gate

/// What the app should be showing right now. The router reads this for its redirect, and
/// `SplashScreen` renders the states that are not a destination.
enum AuthGate {
  /// Supabase is still starting, or the profile read is in flight.
  booting,

  /// Built without `--dart-define`. Not recoverable in-app.
  unconfigured,

  /// `Supabase.initialize` threw. Retryable.
  bootFailed,

  /// No session. Show the login screen.
  signedOut,

  /// Authenticated, but no `app_users` row — nobody put this account in an org.
  unprovisioned,

  /// The profile read failed: offline, or a policy refused it. Retryable.
  profileBlocked,

  /// Signed in and provisioned. Everything else in the app is allowed to build.
  ready,
}

@Riverpod(keepAlive: true)
AuthGate authGate(Ref ref) => switch (ref.watch(bootstrapProvider).valueOrNull) {
      null => AuthGate.booting,
      BootstrapUnconfigured() => AuthGate.unconfigured,
      BootstrapFailed() => AuthGate.bootFailed,
      BootstrapReady() => _gateForSession(ref),
    };

AuthGate _gateForSession(Ref ref) {
  if (ref.watch(currentSessionProvider) == null) return AuthGate.signedOut;
  return switch (ref.watch(currentUserProvider)) {
    AsyncData(value: final user) => user == null ? AuthGate.unprovisioned : AuthGate.ready,
    AsyncError() => AuthGate.profileBlocked,
    _ => AuthGate.booting,
  };
}

// ---------------------------------------------------------------- sign-in

/// Where the phone path has got to, so the login screen can show "we sent a code" without
/// holding that in widget state across a rebuild.
final class AuthFormState {
  const AuthFormState({this.otpSentTo, this.otpSentAt, this.notice});

  /// The E.164 number a code was sent to, or null before one was requested.
  final String? otpSentTo;
  final DateTime? otpSentAt;

  /// A confirmation to show above the form — "We sent a 6-digit code to +91 98765 43210."
  final String? notice;

  bool get awaitingCode => otpSentTo != null;

  /// Supabase rate-limits SMS to roughly one a minute; offering "Resend" before then produces
  /// a failure the operator cannot act on.
  bool get canResend {
    final sent = otpSentAt;
    return sent == null || DateTime.now().difference(sent) > const Duration(seconds: 60);
  }
}

/// Sign-in, sign-out and the phone-OTP handshake.
///
/// Every method funnels through [_run], so the screen only ever reads `isLoading` and a
/// [DhFailure] — and a database or gotrue message reaches the operator in the words the server
/// chose, which is the same discipline the D-011 rules depend on.
@riverpod
class AuthController extends _$AuthController {
  @override
  FutureOr<AuthFormState> build() => const AuthFormState();

  GoTrueClient get _auth => ref.read(supabaseAuthProvider);

  Future<bool> signInWithPassword({
    required String email,
    required String password,
  }) =>
      _run(() async {
        await _auth.signInWithPassword(email: email.trim(), password: password);
        return const AuthFormState();
      });

  /// Start the phone path. The number is normalised to E.164 first — gotrue rejects anything
  /// else, and the rejection reads like a validation bug rather than a typo.
  Future<bool> sendPhoneCode(String phone) {
    final number = normalisePhone(phone);
    return _run(() async {
      await _auth.signInWithOtp(phone: number, shouldCreateUser: false);
      return AuthFormState(
        otpSentTo: number,
        otpSentAt: DateTime.now(),
        notice: 'We sent a 6-digit code to $number.',
      );
    });
  }

  /// Finish the phone path.
  Future<bool> verifyPhoneCode(String code) {
    final number = state.valueOrNull?.otpSentTo;
    if (number == null) {
      state = AsyncError(
        const AuthFailure(message: 'Request a code first, then enter it here.'),
        StackTrace.current,
      );
      return Future.value(false);
    }
    return _run(() async {
      await _auth.verifyOTP(
        phone: number,
        token: code.trim(),
        type: OtpType.sms,
      );
      return const AuthFormState();
    });
  }

  /// Drop back to the phone entry field — "wrong number".
  void clearPhoneCode() => state = const AsyncData(AuthFormState());

  Future<bool> sendPasswordReset(String email) => _run(() async {
        await _auth.resetPasswordForEmail(email.trim());
        return AuthFormState(
          notice: 'Check ${email.trim()} for a link to set a new password.',
        );
      });

  /// Sign out, and take the realtime channels with it.
  ///
  /// D-008: a partner's job channels are subscribed under that partner's JWT. Leaving them open
  /// across a sign-out on a shared shop-floor tablet would keep pushing one vendor's rows into
  /// the next vendor's session.
  Future<bool> signOut() => _run(() async {
        final client = ref.read(supabaseProvider);
        await client.removeAllChannels();
        await client.auth.signOut();
        return const AuthFormState();
      });

  Future<bool> _run(Future<AuthFormState> Function() body) async {
    state = const AsyncLoading<AuthFormState>().copyWithPrevious(state);
    try {
      state = AsyncData(await body());
      return true;
    } on Object catch (error, stack) {
      state = AsyncError(toDhFailure(error, stack), stack);
      return false;
    }
  }
}

/// Supabase needs E.164. Operators type a ten-digit Indian mobile, because the manufacturer is
/// an Indian entity (D-004) and so is most of the bench.
String normalisePhone(String input) {
  final trimmed = input.trim();
  final digits = trimmed.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return '';
  if (trimmed.startsWith('+')) return '+$digits';
  if (digits.length == 10) return '+91$digits';
  if (digits.length == 12 && digits.startsWith('91')) return '+$digits';
  if (digits.length == 11 && digits.startsWith('0')) return '+91${digits.substring(1)}';
  return '+$digits';
}
