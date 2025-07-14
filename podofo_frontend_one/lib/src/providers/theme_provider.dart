import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UserPreference {
  final ThemeMode themeMode;
  final bool shaderPreference;
  final double shaderStrength;

  UserPreference({
    this.themeMode = ThemeMode.system,
    this.shaderPreference = false,
    this.shaderStrength = 1.0,
  });

  UserPreference copyWith({
    ThemeMode? themeMode,
    bool? shaderPreference,
    double? shaderStrength,
  }) {
    return UserPreference(
      themeMode: themeMode ?? this.themeMode,
      shaderPreference: shaderPreference ?? this.shaderPreference,
      shaderStrength: shaderStrength ?? this.shaderStrength,
    );
  }
}

class UserPreferenceNotifier extends AsyncNotifier<UserPreference> {
  @override
  Future<UserPreference> build() async {
    final prefs = await SharedPreferences.getInstance();
    final themeModeName = prefs.getString('themeMode');
    final themeMode = themeModeName != null
        ? ThemeMode.values.firstWhere(
            (e) => e.name == themeModeName,
            orElse: () => ThemeMode.system,
          )
        : ThemeMode.system;
    final shaderPreference = prefs.getBool('shaderPreference') ?? false;
    final shaderStrength = prefs.getDouble('shaderStrength') ?? 1.0;
    return UserPreference(
      themeMode: themeMode,
      shaderPreference: shaderPreference,
      shaderStrength: shaderStrength,
    );
  }

  Future<void> setThemeMode(ThemeMode themeMode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('themeMode', themeMode.name);
    state = AsyncValue.data(state.value!.copyWith(themeMode: themeMode));
  }

  Future<void> setShaderPreference(bool shaderPreference) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('shaderPreference', shaderPreference);
    state = AsyncValue.data(
      state.value!.copyWith(shaderPreference: shaderPreference),
    );
  }

  Future<void> setShaderStrength(double shaderStrength) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('shaderStrength', shaderStrength);
    state = AsyncValue.data(
      state.value!.copyWith(shaderStrength: shaderStrength),
    );
  }
}

final userPreferenceProvider =
    AsyncNotifierProvider<UserPreferenceNotifier, UserPreference>(
      UserPreferenceNotifier.new,
    );

final themeModeProvider = Provider<ThemeMode>((ref) {
  return ref.watch(userPreferenceProvider).value?.themeMode ?? ThemeMode.system;
});

final brightnessProvider = Provider<Brightness>((ref) {
  final themeMode = ref.watch(themeModeProvider);
  // NOTE: This does not react to system theme changes.
  final platformBrightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;
  switch (themeMode) {
    case ThemeMode.light:
      return Brightness.light;
    case ThemeMode.dark:
      return Brightness.dark;
    case ThemeMode.system:
      return platformBrightness;
  }
});

// HACK: This is copy-pasted from `main.dart` and does not properly implement
//       state reactivity.
Typography typography = const Typography.geist().copyWith(
  sans: const TextStyle(fontFamily: 'Urbanist'),
);

final themeDataProvider = Provider<ThemeData>((ref) {
  final brightness = ref.watch(brightnessProvider);
  final colorScheme = brightness == Brightness.dark
      ? ColorSchemes.darkZinc()
      : ColorSchemes.lightZinc();
  return ThemeData(
    typography: typography,
    colorScheme: colorScheme,
    radius: 0.5,
  );
});

final shaderProvider = NotifierProvider<ShaderNotifier, FragmentShader?>(
  ShaderNotifier.new,
);

class ShaderNotifier extends Notifier<FragmentShader?> {
  FragmentProgram? _program;

  @override
  FragmentShader? build() {
    _loadProgram();

    final userPreference = ref.watch(userPreferenceProvider).value;
    final preference = userPreference?.shaderPreference ?? false;
    final strength = userPreference?.shaderStrength ?? 1.0;

    if (_program == null) {
      return null;
    }

    if (preference) {
      // return _program!.fragmentShader()..setFloat(2, strength);
      ref.read(userPreferenceProvider.notifier).setShaderPreference(true);
    } else {
      // return _program!.fragmentShader()..setFloat(2, 0.0);
      ref.read(userPreferenceProvider.notifier).setShaderPreference(false);
    }

    return _program!.fragmentShader()..setFloat(2, strength);
  }

  Future<void> _loadProgram() async {
    if (_program != null) return;
    try {
      _program = await FragmentProgram.fromAsset('shaders/invert.frag');
      ref.invalidateSelf();
    } catch (e, s) {
      print('Failed to load shader: $e');
      print(s);
    }
  }
}

final shaderStrengthProvider = Provider<double>((ref) {
  return ref.watch(userPreferenceProvider).value?.shaderStrength ?? 1.0;
});

final shaderPreferenceProvider = Provider<bool>((ref) {
  return ref.watch(userPreferenceProvider).value?.shaderPreference ?? false;
});
