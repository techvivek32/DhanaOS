/// The one Supabase client the app reads, and the guarded bootstrap that produces it.
///
/// D-007 puts Postgres, Auth, Storage and Realtime behind a single client. Two things make
/// this file more than a one-liner:
///
///  * **The anon key never ships in the repo.** It arrives through `--dart-define` (see
///    `core/config.dart`), so a build can legitimately be missing it. A missing key must
///    produce a screen that says which command to run — not a red frame on a released APK.
///  * **Bootstrap failure is a state, not an exception.** `Supabase.initialize` touches
///    platform storage to restore a session; on a locked or wiped device it can throw. The
///    splash screen renders that as a retryable state instead of taking the app down.
///
/// Nothing else in the app calls `Supabase.initialize` or `Supabase.instance`.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dhanaos/core/config.dart';
import 'package:dhanaos/data/supabase/errors.dart';

part 'client.g.dart';

// ---------------------------------------------------------------- bootstrap result

/// What came back from [initSupabase]. Exhaustive so the splash screen cannot forget a case.
sealed class Bootstrap {
  const Bootstrap();

  bool get isReady => this is BootstrapReady;
}

/// The client is live and the persisted session, if any, has been restored.
final class BootstrapReady extends Bootstrap {
  const BootstrapReady(this.client);

  final SupabaseClient client;
}

/// Built without `SUPABASE_URL` / `SUPABASE_ANON_KEY`. [message] is
/// `Config.missingConfigMessage`, which already names the command to fix it.
final class BootstrapUnconfigured extends Bootstrap {
  const BootstrapUnconfigured(this.message);

  final String message;
}

/// The keys were present but initialisation threw — usually platform storage, occasionally a
/// malformed URL. Retryable.
final class BootstrapFailed extends Bootstrap {
  const BootstrapFailed(this.failure);

  final DhFailure failure;
}

// ---------------------------------------------------------------- init

/// Initialise Supabase without ever throwing.
///
/// Safe to call more than once: `Supabase.initialize` returns the existing instance when it is
/// already up, which is what makes a retry button on the splash screen cheap.
Future<Bootstrap> initSupabase() async {
  if (!Config.isConfigured) {
    return BootstrapUnconfigured(Config.missingConfigMessage);
  }
  try {
    final instance = await Supabase.initialize(
      url: Config.supabaseUrl,
      // `anonKey` is deprecated in supabase_flutter 2.17; both parameters feed the same
      // publishable key. The key is safe in an APK only because every table is behind RLS
      // (0009_rls.sql) — that is what makes D-008 load bearing rather than decorative.
      publishableKey: Config.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        // Sessions survive an app restart so a bench operator is not signing in every shift.
        persistSession: true,
      ),
      // Shop-floor wifi drops mid-upload. Three retries is the difference between a caster
      // re-shooting a casting photo and not — D-011 rule 1 depends on that photo landing.
      storageOptions: const StorageClientOptions(retryAttempts: 3),
    );
    return BootstrapReady(instance.client);
  } on Object catch (error, stack) {
    return BootstrapFailed(toDhFailure(error, stack));
  }
}

// ---------------------------------------------------------------- providers

/// Runs [initSupabase] once for the process. Kept alive: re-initialising would drop every
/// realtime channel and the restored session with them.
@Riverpod(keepAlive: true)
Future<Bootstrap> bootstrap(Ref ref) => initSupabase();

/// The client. Reading this before [bootstrapProvider] has resolved is a programming error,
/// not a runtime condition — `SplashScreen` (and the router's redirect, which reads
/// `authGateProvider`) gate every other surface on the bootstrap state first.
@Riverpod(keepAlive: true)
SupabaseClient supabase(Ref ref) {
  final result = ref.watch(bootstrapProvider).value;
  return switch (result) {
    BootstrapReady(:final client) => client,
    BootstrapUnconfigured(:final message) => throw StateError(message),
    BootstrapFailed(:final failure) => throw StateError(
        'Supabase did not start: ${failure.message}',
      ),
    null => throw StateError(
        'supabaseProvider was read before bootstrapProvider resolved. Gate the widget on '
        'authGateProvider or on SplashScreen.',
      ),
  };
}

/// Auth only. Screens that sign in or out reach this instead of the whole client.
@Riverpod(keepAlive: true)
GoTrueClient supabaseAuth(Ref ref) => ref.watch(supabaseProvider).auth;
