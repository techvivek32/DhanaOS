/// Entry point.
///
/// Deliberately thin. Only two things genuinely have to happen before the first frame — the
/// binding, and the en_IN locale data that every `Money` and `DateFormat` call depends on — so
/// only those are here.
///
/// **Supabase is not started here.** `data/supabase/client.dart` owns `Supabase.initialize`
/// behind `bootstrapProvider`, which turns a missing `--dart-define` or a platform-storage
/// failure into a *state* the splash screen can explain and retry rather than an exception
/// before `runApp`. Starting it in both places would give the app two answers to "is the
/// backend up", and the one in `main` cannot be retried.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // D-004 and convention 7. Postgres hands us UTC; every screen renders local time through
  // intl, and money groups the Indian way (lakh / crore). Both need the locale loaded before
  // the first format call, and `DateFormat` throws rather than falling back if it is not.
  final localeTag = '${appLocale.languageCode}_${appLocale.countryCode}';
  Intl.defaultLocale = localeTag;
  await initializeDateFormatting(localeTag);

  // Android 15 draws behind the system bars whether an app asks or not. Declaring the mode
  // means the shell's own SafeArea does the insetting instead of the system guessing at it.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  runApp(const ProviderScope(child: DhanaOsApp()));
}
