/// Entry point of the DhanaOS web admin panel.
///
///   flutter run -d chrome -t lib/admin/main.dart --dart-define-from-file=env/dev.json
///   flutter build web -t lib/admin/main.dart --dart-define-from-file=env/prod.json -o build/admin
///
/// Same Supabase project, same design system and models as the Android app, a separate console:
/// the platform's super admins manage workspaces, and each workspace's admins manage its people,
/// customers, partners and settings (0014).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dhanaos/admin/admin_router.dart';
import 'package:dhanaos/admin/theme_mode.dart';
import 'package:dhanaos/core/theme/app_theme.dart';

/// The app's locale (lib/app.dart), repeated rather than imported: app.dart pulls in the mobile
/// router and every device-only screen behind it.
const appLocale = Locale('en', 'IN');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final localeTag = '${appLocale.languageCode}_${appLocale.countryCode}';
  Intl.defaultLocale = localeTag;
  await initializeDateFormatting(localeTag);

  final prefs = await SharedPreferences.getInstance();

  // As in the app: a failure here is an RLS refusal or a rule, and retrying cannot change it.
  runApp(
    ProviderScope(
      retry: _noRetry,
      overrides: [adminPrefsProvider.overrideWithValue(prefs)],
      child: const AdminApp(),
    ),
  );
}

Duration? _noRetry(int retryCount, Object error) => null;

final class AdminApp extends ConsumerWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: 'DhanaOS Admin',
    debugShowCheckedModeBanner: false,
    routerConfig: ref.watch(adminRouterProvider),
    theme: _desktop(AppTheme.light()),
    darkTheme: _desktop(AppTheme.dark()),
    themeMode: ref.watch(adminThemeModeProvider),
    locale: appLocale,
    supportedLocales: const <Locale>[appLocale, Locale('en', 'US')],
  );
}

/// The app's buttons are full-width with a 52px thumb target — right on a phone, wrong in a
/// desktop header. Same colours and shape; sized to their label, at the shell's row height.
ThemeData _desktop(ThemeData base) {
  const size = WidgetStatePropertyAll(Size(64, 44));
  return base.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: (base.filledButtonTheme.style ?? const ButtonStyle()).copyWith(minimumSize: size),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: (base.outlinedButtonTheme.style ?? const ButtonStyle()).copyWith(minimumSize: size),
    ),
  );
}
