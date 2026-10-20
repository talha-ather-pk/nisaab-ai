import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_providers.dart';

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    Future.microtask(_restore);
    return ThemeMode.system;
  }

  Future<void> _restore() async {
    final saved = await ref.read(tokenStorageProvider).readThemeMode();
    final mode = ThemeMode.values.where((m) => m.name == saved).firstOrNull;
    if (mode != null) state = mode;
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await ref.read(tokenStorageProvider).saveThemeMode(mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
