/// Light, dark, or whatever the computer is set to — the admin panel's choice, remembered in the
/// browser. D-010: one component set, two themes; this only picks which one is showing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dhanaos/shared/widgets/segmented.dart';

part 'theme_mode.g.dart';

/// Loaded in `main` before the first frame, so a dark-mode admin never sees a light flash.
@Riverpod(keepAlive: true)
SharedPreferences adminPrefs(Ref ref) =>
    throw UnimplementedError('adminPrefsProvider is overridden in lib/admin/main.dart');

@Riverpod(keepAlive: true)
class AdminThemeMode extends _$AdminThemeMode {
  static const _key = 'dhanaos.admin.themeMode';

  @override
  ThemeMode build() {
    final saved = ref.watch(adminPrefsProvider).getString(_key);
    return ThemeMode.values.firstWhere((m) => m.name == saved, orElse: () => ThemeMode.system);
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await ref.read(adminPrefsProvider).setString(_key, mode.name);
  }
}

/// Auto · Light · Dark, on the design system's own segmented control.
final class ThemeModeSwitch extends ConsumerWidget {
  const ThemeModeSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DhSegmented<ThemeMode>(
    value: ref.watch(adminThemeModeProvider),
    dense: true,
    segments: const [
      DhSegment(value: ThemeMode.system, label: 'Auto', icon: Icons.brightness_auto_outlined),
      DhSegment(value: ThemeMode.light, label: 'Light', icon: Icons.light_mode_outlined),
      DhSegment(value: ThemeMode.dark, label: 'Dark', icon: Icons.dark_mode_outlined),
    ],
    onChanged: (mode) => ref.read(adminThemeModeProvider.notifier).set(mode),
  );
}
