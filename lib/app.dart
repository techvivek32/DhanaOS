/// The root widget.
///
/// D-010 in one place: one component set, two token sets, and the theme mode follows the
/// device. Light is the product default (38 of 46 mockups); dark is the shop-floor and phone
/// theme (the other 8). Neither is a separate screen set — an operator switching their phone to
/// dark gets the same widgets in the other palette.
///
/// There is no "backend missing" variant of this widget. A build without `--dart-define` is a
/// state of `bootstrapProvider`, which `SplashScreen` renders at `/` with the exact command to
/// fix it — so that case reaches the operator through the normal app, themed and readable,
/// rather than through a second MaterialApp that bypasses the router.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';

/// D-004. The manufacturer is an Indian entity, so INR grouping (lakh / crore), Indian ring
/// sizing and en_IN dates are the default rather than something an operator has to select.
/// `main()` hands the same tag to `Intl.defaultLocale`, so widget formatting and the
/// `Money` / `DateFormat` helpers can never disagree.
const appLocale = Locale('en', 'IN');

final class DhanaOsApp extends ConsumerWidget {
  const DhanaOsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'DhanaOS',
      debugShowCheckedModeBanner: false,
      routerConfig: ref.watch(routerProvider),
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      locale: appLocale,
      // en_US is listed so a device set to US English resolves to a supported locale instead
      // of falling back to the first entry by accident.
      supportedLocales: const <Locale>[appLocale, Locale('en', 'US')],
    );
  }
}
