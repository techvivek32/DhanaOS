/// One typed failure for everything the backend can refuse, and one place that decides what
/// the operator reads.
///
/// The load-bearing case is [RuleViolation]. The four D-011 business rules are enforced by
/// Postgres (`fn_complete_stage`, `fn_dispatch_shipment`, the `cad_reject_needs_comment`
/// CHECK) and they raise `check_violation` with text already written from the operator's side:
///
///   "A casting photo is required before marking this stage complete"
///   "Complete the security protocol first — 2 check(s) outstanding"
///
/// Those strings are the product. They are surfaced **verbatim** — never wrapped in an
/// apology, never replaced by a generic "Something went wrong", never re-implemented in Dart
/// where a client rewrite could weaken them.
library;

import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Coarse classification, for logging and for deciding whether a retry button makes sense.
enum FailureKind {
  /// A business rule said no. The message is authored by the database.
  rule,

  /// RLS or a grant refused the row. D-008 working as designed.
  permission,

  /// The row is not there, or is not visible to this principal.
  notFound,

  /// A unique index rejected the write.
  duplicate,

  /// A foreign key pointed at nothing.
  reference,

  /// A NOT NULL column arrived empty.
  missingField,

  /// Sign-in, OTP, session.
  auth,

  /// Storage upload, download or removal.
  storage,

  /// No route to the server.
  network,

  /// Anything the server could not process.
  server,
}

/// The single error type every repository throws. Screens switch on the subtype.
sealed class DhFailure implements Exception {
  const DhFailure({required this.message, this.detail, this.code});

  /// What the operator reads. Always a complete sentence written from their side of the
  /// screen: what went wrong, and what to do about it.
  final String message;

  /// Developer context — the SQL detail, the hint, the offending constraint. Shown only in a
  /// diagnostics sheet or a log, never as the headline.
  final String? detail;

  /// SQLSTATE ('23514'), PostgREST code ('PGRST116'), gotrue code ('invalid_credentials') or
  /// an HTTP status. Kept so tests can assert on a rule without matching prose.
  final String? code;

  FailureKind get kind;

  /// True when pressing the same button again could plausibly succeed.
  bool get isRetryable => switch (kind) {
        FailureKind.network || FailureKind.server => true,
        _ => false,
      };

  /// True when the fix is for the operator to change something on screen first.
  bool get isUserFixable => switch (kind) {
        FailureKind.rule ||
        FailureKind.missingField ||
        FailureKind.duplicate ||
        FailureKind.auth =>
          true,
        _ => false,
      };

  @override
  String toString() => '$runtimeType($code): $message${detail == null ? '' : ' — $detail'}';
}

/// D-011. A rule in `0008_functions.sql` refused the transition. [message] is the database's
/// own words and must reach the operator unaltered.
final class RuleViolation extends DhFailure {
  const RuleViolation({
    required super.message,
    super.detail,
    super.code,
  });

  @override
  FailureKind get kind => FailureKind.rule;
}

/// RLS or a column grant refused. D-008: a partner reaching another partner's job lands here,
/// and that is the system working.
final class PermissionDenied extends DhFailure {
  const PermissionDenied({
    required super.message,
    super.detail,
    super.code,
    this.sessionExpired = false,
  });

  /// True for an expired or malformed JWT — the caller should send the operator back to
  /// sign-in rather than showing a permissions message.
  final bool sessionExpired;

  @override
  FailureKind get kind => FailureKind.permission;
}

final class RecordNotFound extends DhFailure {
  const RecordNotFound({required super.message, super.detail, super.code});

  @override
  FailureKind get kind => FailureKind.notFound;
}

final class DuplicateRecord extends DhFailure {
  const DuplicateRecord({required super.message, super.detail, super.code});

  @override
  FailureKind get kind => FailureKind.duplicate;
}

final class InvalidReference extends DhFailure {
  const InvalidReference({required super.message, super.detail, super.code});

  @override
  FailureKind get kind => FailureKind.reference;
}

final class MissingRequiredField extends DhFailure {
  const MissingRequiredField({required super.message, super.detail, super.code});

  @override
  FailureKind get kind => FailureKind.missingField;
}

final class AuthFailure extends DhFailure {
  const AuthFailure({
    required super.message,
    super.detail,
    super.code,
    this.retryAfter,
  });

  /// Set when the server rate-limited us, so the UI can count down instead of inviting a
  /// retry that will also fail.
  final Duration? retryAfter;

  /// The password or email is wrong — keep the operator on the form with the password
  /// cleared, do not clear the email.
  bool get isBadCredentials =>
      code == 'invalid_credentials' || code == 'invalid_grant' || code == 'user_not_found';

  /// The code was right once but has aged out. Offer "Send a new code", not "Try again".
  bool get isExpiredCode => code == 'otp_expired' || code == 'flow_state_expired';

  bool get isRateLimited =>
      code == 'over_request_rate_limit' ||
      code == 'over_sms_send_rate_limit' ||
      code == 'over_email_send_rate_limit' ||
      code == '429';

  bool get needsConfirmation =>
      code == 'email_not_confirmed' || code == 'phone_not_confirmed';

  @override
  FailureKind get kind => FailureKind.auth;
}

final class StorageFailure extends DhFailure {
  const StorageFailure({required super.message, super.detail, super.code});

  @override
  FailureKind get kind => FailureKind.storage;
}

final class NetworkFailure extends DhFailure {
  const NetworkFailure({required super.message, super.detail, super.code});

  @override
  FailureKind get kind => FailureKind.network;
}

final class ServerFailure extends DhFailure {
  const ServerFailure({required super.message, super.detail, super.code});

  @override
  FailureKind get kind => FailureKind.server;
}

// ---------------------------------------------------------------- mapping

/// SQLSTATE classes we name. The rest fall through to [ServerFailure].
abstract final class SqlState {
  /// `raise ... using errcode = 'check_violation'` — every D-011 rule lands here.
  static const checkViolation = '23514';

  /// `raise exception` with no errcode — the guard clauses inside the same functions.
  static const raiseException = 'P0001';

  static const notNullViolation = '23502';
  static const foreignKeyViolation = '23503';
  static const uniqueViolation = '23505';
  static const exclusionViolation = '23P01';
  static const insufficientPrivilege = '42501';
  static const undefinedTable = '42P01';
  static const undefinedColumn = '42703';
  static const invalidTextRepresentation = '22P02';
  static const numericOutOfRange = '22003';
  static const serializationFailure = '40001';
  static const deadlockDetected = '40P01';
  static const queryCanceled = '57014';
}

extension PostgrestExceptionX on PostgrestException {
  /// D-011. True when this is one of the four business rules, not an infrastructure fault.
  /// The caller shows [message] as-is.
  bool get isBusinessRule =>
      code == SqlState.checkViolation || code == SqlState.raiseException;
}

/// Translate anything thrown by the Supabase client into a [DhFailure].
///
/// The order matters: the business-rule branch is checked before every generic Postgrest
/// branch so a rule message can never be swallowed by a friendlier-sounding default.
DhFailure toDhFailure(Object error, [StackTrace? stack]) {
  if (error is DhFailure) return error;
  if (error is PostgrestException) return _fromPostgrest(error);
  if (error is AuthException) return _fromAuth(error);
  if (error is StorageException) return _fromStorage(error);
  if (error is RealtimeSubscribeException) {
    return NetworkFailure(
      message: 'Live updates are not connected. Pull to refresh to see the latest state.',
      detail: error.toString(),
      code: error.status.name,
    );
  }
  if (_isTransportError(error)) {
    return NetworkFailure(
      message: 'No connection to the server. Check the network and try again.',
      detail: error.toString(),
    );
  }
  if (error is TimeoutException) {
    return NetworkFailure(
      message: 'The server took too long to answer. Try again.',
      detail: error.message,
    );
  }
  if (error is FormatException) {
    return ServerFailure(
      message: 'The server sent something this build cannot read. Update the app.',
      detail: error.message,
    );
  }
  return ServerFailure(message: 'Unexpected error. Try again.', detail: error.toString());
}

DhFailure _fromPostgrest(PostgrestException e) {
  final detail = _joinDetail(e.details, e.hint);

  // D-011 first, always. These messages are the product.
  if (e.isBusinessRule) {
    return RuleViolation(message: e.message, detail: detail, code: e.code);
  }

  return switch (e.code) {
    SqlState.insufficientPrivilege || '401' || '403' => PermissionDenied(
        message: 'You do not have permission to do that. Ask an admin for the role you need.',
        detail: detail ?? e.message,
        code: e.code,
      ),

    // PostgREST's JWT codes. The session is stale, not the permission set.
    'PGRST301' || 'PGRST302' || 'PGRST303' => PermissionDenied(
        message: 'Your session expired. Sign in again to continue.',
        detail: e.message,
        code: e.code,
        sessionExpired: true,
      ),

    // `.single()` matched no row — usually invisible-by-RLS rather than absent.
    'PGRST116' || '404' => RecordNotFound(
        message: 'That record is no longer there, or it is not yours to see.',
        detail: detail ?? e.message,
        code: e.code,
      ),

    SqlState.uniqueViolation || '409' => DuplicateRecord(
        message: _duplicateMessage(e),
        detail: detail ?? e.message,
        code: e.code,
      ),

    SqlState.foreignKeyViolation => InvalidReference(
        message: 'A linked record is missing. Save the parent record first, then retry.',
        detail: detail ?? e.message,
        code: e.code,
      ),

    SqlState.notNullViolation => MissingRequiredField(
        message: 'A required field is empty. Fill it in and save again.',
        detail: detail ?? e.message,
        code: e.code,
      ),

    SqlState.numericOutOfRange => MissingRequiredField(
        message: 'A number is out of range for its field. Check the weights and carats.',
        detail: detail ?? e.message,
        code: e.code,
      ),

    // Convention 6, caught in the wild: a `22P02` on an enum column almost always means a
    // Dart enum crossed the wire as `.name` instead of `.wire`.
    SqlState.invalidTextRepresentation => ServerFailure(
        message: 'This build sent a value the database does not recognise. Update the app.',
        detail: 'Check for an enum sent as .name instead of .wire. ${detail ?? e.message}',
        code: e.code,
      ),

    SqlState.serializationFailure || SqlState.deadlockDetected => ServerFailure(
        message: 'Someone else changed this at the same moment. Try again.',
        detail: detail ?? e.message,
        code: e.code,
      ),

    SqlState.queryCanceled => NetworkFailure(
        message: 'The query timed out. Try again, or narrow the filter.',
        detail: detail ?? e.message,
        code: e.code,
      ),

    SqlState.undefinedTable || SqlState.undefinedColumn || 'PGRST204' || 'PGRST205' =>
      ServerFailure(
        message: 'The database is behind this build. Apply the migrations in '
            'supabase/migrations, then retry.',
        detail: detail ?? e.message,
        code: e.code,
      ),

    _ => ServerFailure(message: e.message, detail: detail, code: e.code),
  };
}

/// `jobs_code_uq` and `jobs_draft_code_uq` are the two unique indexes an operator can actually
/// collide with, so name the field rather than saying "duplicate key".
String _duplicateMessage(PostgrestException e) {
  final text = '${e.message} ${e.details ?? ''}'.toLowerCase();
  if (text.contains('code')) {
    return 'That code is already used. Pick another and save again.';
  }
  return 'That record already exists. Change what makes it unique and save again.';
}

DhFailure _fromAuth(AuthException e) {
  final code = e.code ?? e.statusCode;
  final message = switch (code) {
    'invalid_credentials' || 'invalid_grant' =>
      'Email or password is wrong. Check both and try again.',
    'user_not_found' => 'No account for that email. Ask an admin to invite you.',
    'email_not_confirmed' =>
      'This email is not confirmed yet. Open the link we sent, then sign in.',
    'phone_not_confirmed' => 'This number is not confirmed yet. Request a new code.',
    'otp_expired' => 'That code has expired. Send a new one.',
    'validation_failed' => 'Check the email or phone number — the format is not valid.',
    'over_request_rate_limit' || 'over_sms_send_rate_limit' || 'over_email_send_rate_limit' =>
      'Too many attempts. Wait a minute, then try once more.',
    'weak_password' => 'That password is too weak. Use at least 8 characters.',
    'same_password' => 'That is the password you already have. Choose a different one.',
    'signup_disabled' => 'Self sign-up is off. An admin has to create your account.',
    'user_banned' => 'This account is suspended. Contact an admin.',
    'session_expired' || 'session_not_found' || 'session_missing' =>
      'Your session expired. Sign in again.',
    'sms_send_failed' => 'The SMS could not be sent. Try email and password instead.',
    'phone_provider_disabled' =>
      'Phone sign-in is not enabled on this project. Use email and password.',
    'captcha_failed' => 'The security check failed. Try again.',
    '429' => 'Too many attempts. Wait a minute, then try once more.',
    _ => e.message,
  };
  return AuthFailure(
    message: message,
    detail: e.message,
    code: code,
    retryAfter: _rateLimitWindow(code),
  );
}

/// Supabase's default SMS and email windows. Used only to drive a countdown; the server is
/// still the authority on when the next send is accepted.
Duration? _rateLimitWindow(String? code) => switch (code) {
      'over_sms_send_rate_limit' => const Duration(seconds: 60),
      'over_email_send_rate_limit' => const Duration(seconds: 60),
      'over_request_rate_limit' || '429' => const Duration(seconds: 30),
      _ => null,
    };

DhFailure _fromStorage(StorageException e) => switch (e.statusCode) {
      '401' || '403' => PermissionDenied(
          message: 'You do not have permission to use that bucket.',
          detail: e.message,
          code: e.statusCode,
        ),
      '404' => RecordNotFound(
          message: 'That file is no longer in storage.',
          detail: e.message,
          code: e.statusCode,
        ),
      '409' => DuplicateRecord(
          message: 'A file already exists at that path. Rename it or allow an overwrite.',
          detail: e.message,
          code: e.statusCode,
        ),
      '413' => StorageFailure(
          message: 'That file is too large for this bucket. Compress it and upload again.',
          detail: e.message,
          code: e.statusCode,
        ),
      _ => StorageFailure(
          message: 'The file could not be transferred. Check the connection and try again.',
          detail: e.message,
          code: e.statusCode,
        ),
    };

/// `IOException` covers the `dart:io` transport family — `SocketException` (no route, failed
/// host lookup), `HttpException`, `TlsException`. `package:http` is not a direct dependency of
/// this app, so its `ClientException` is matched by name rather than by type.
bool _isTransportError(Object error) =>
    error is IOException || error.runtimeType.toString() == 'ClientException';

String? _joinDetail(Object? details, String? hint) {
  final parts = <String>[
    if (details != null && '$details'.isNotEmpty) '$details',
    if (hint != null && hint.isNotEmpty) hint,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

// ---------------------------------------------------------------- call wrappers

/// Run a Supabase call and convert any throw into a [DhFailure], preserving the stack.
///
/// Every repository in `lib/data` goes through this, which is why no screen ever has to know
/// what a `PostgrestException` is.
Future<T> guard<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on Object catch (error, stack) {
    Error.throwWithStackTrace(toDhFailure(error, stack), stack);
  }
}

/// [guard] for a call whose absent result is a normal outcome — a `maybeSingle()` that found
/// nothing, a file that was already removed.
Future<T?> guardOrNull<T>(Future<T?> Function() body) async {
  try {
    return await body();
  } on Object catch (error, stack) {
    final failure = toDhFailure(error, stack);
    if (failure.kind == FailureKind.notFound) return null;
    Error.throwWithStackTrace(failure, stack);
  }
}
